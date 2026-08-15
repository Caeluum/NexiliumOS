#!/usr/bin/env bash
set -euo pipefail

ROOTFS="/opt/nexilium-rootfs"
ISO_ROOT="/opt/nexilium-iso"
OUTPUT="$(pwd)/output"
ISO_NAME="NexiliumOS.iso"

echo "==> Checando dependências do host..."
REQUIRED_HOST_BINS=(debootstrap mksquashfs grub-mkrescue xorriso)
MISSING=()
for bin in "${REQUIRED_HOST_BINS[@]}"; do
    command -v "$bin" >/dev/null 2>&1 || MISSING+=("$bin")
done
if [ "${#MISSING[@]}" -gt 0 ]; then
    echo "ERRO: faltam ferramentas no host: ${MISSING[*]}"
    echo "Instale com: sudo apt-get install debootstrap squashfs-tools grub-pc-bin grub-efi-amd64-bin grub-common xorriso mtools"
    exit 1
fi

# Garante que os mounts virtuais sejam desfeitos mesmo se o script falhar no meio
cleanup_mounts() {
    for mnt in dev/pts dev sys proc; do
        mountpoint -q "$ROOTFS/$mnt" 2>/dev/null && sudo umount -lf "$ROOTFS/$mnt" || true
    done
}
trap cleanup_mounts EXIT

# Limpa mounts antigos se existirem (ex: execução anterior interrompida)
cleanup_mounts

echo "==> Bootstrap Debian Trixie..."
sudo debootstrap --arch=amd64 trixie "$ROOTFS" http://deb.debian.org/debian

echo "==> Copiando configs..."
sudo cp config/sources.list      "$ROOTFS/etc/apt/sources.list"
sudo cp config/os-release        "$ROOTFS/etc/os-release"
sudo cp config/packages.list     "$ROOTFS/tmp/packages.list"
sudo cp scripts/chroot-setup.sh  "$ROOTFS/tmp/chroot-setup.sh"
sudo chmod +x "$ROOTFS/tmp/chroot-setup.sh"

echo "==> Copiando wallpaper padrão..."
sudo mkdir -p "$ROOTFS/usr/share/backgrounds/nexiliumos"
sudo cp assets/sla.png "$ROOTFS/usr/share/backgrounds/nexiliumos/sla.png"

echo "==> Copiando configuração do Calamares (staging, aplicada depois do apt)..."
# NÃO copiamos direto pra /etc/calamares aqui. O pacote calamares-settings-debian
# (instalado como Recommends do pacote calamares) tem um post-install script
# que gerencia esses mesmos arquivos (settings.conf, branding.desc etc) e
# quebra se já encontrar um arquivo nosso no lugar antes dele rodar. Por isso
# copiamos pra um staging em /tmp, e o chroot-setup.sh só move pra
# /etc/calamares DEPOIS que o apt-get install (e a remoção do
# calamares-settings-debian) já rodaram.
sudo mkdir -p "$ROOTFS/tmp/calamares-config"
sudo cp -r config/calamares/. "$ROOTFS/tmp/calamares-config/"

echo "==> Montando filesystems virtuais..."
sudo mount --bind /proc    "$ROOTFS/proc"
sudo mount --bind /sys     "$ROOTFS/sys"
sudo mount --bind /dev     "$ROOTFS/dev"
sudo mount --bind /dev/pts "$ROOTFS/dev/pts"

echo "==> Rodando setup no chroot..."
sudo chroot "$ROOTFS" /tmp/chroot-setup.sh

echo "==> Regenerando initramfs (garante que os hooks do live-boot entrem no initrd)..."
sudo chroot "$ROOTFS" update-initramfs -u -k all

echo "==> Desmontando..."
cleanup_mounts

echo "==> Gerando squashfs..."
mkdir -p "$OUTPUT"
sudo mksquashfs "$ROOTFS" "$OUTPUT/filesystem.squashfs" -comp xz -noappend \
    | grep -v "Unrecognised xattr" || true
SQUASHFS_STATUS="${PIPESTATUS[0]}"
if [ "$SQUASHFS_STATUS" -ne 0 ]; then
    echo "ERRO: mksquashfs falhou (status $SQUASHFS_STATUS)"
    exit 1
fi

echo "==> Montando estrutura do ISO..."
sudo rm -rf "$ISO_ROOT"
sudo mkdir -p "$ISO_ROOT"/{live,boot/grub}

sudo cp "$OUTPUT/filesystem.squashfs" "$ISO_ROOT/live/"

# Pega a versão mais recente do kernel/initrd, caso existam múltiplas
KERNEL_FILE="$(sudo find "$ROOTFS/boot" -maxdepth 1 -name 'vmlinuz-*' | sort -V | tail -n1)"
INITRD_FILE="$(sudo find "$ROOTFS/boot" -maxdepth 1 -name 'initrd.img-*' | sort -V | tail -n1)"

if [ -z "$KERNEL_FILE" ] || [ -z "$INITRD_FILE" ]; then
    echo "ERRO: kernel ou initrd não encontrados em $ROOTFS/boot"
    exit 1
fi

sudo cp "$KERNEL_FILE" "$ISO_ROOT/boot/vmlinuz"
sudo cp "$INITRD_FILE" "$ISO_ROOT/boot/initrd.img"

sudo tee "$ISO_ROOT/boot/grub/grub.cfg" > /dev/null << 'GRUB'
set default=0
set timeout=5

menuentry "NexiliumOS" {
    linux  /boot/vmlinuz boot=live quiet splash
    initrd /boot/initrd.img
}

menuentry "NexiliumOS (modo seguro)" {
    linux  /boot/vmlinuz boot=live nomodeset
    initrd /boot/initrd.img
}
GRUB

echo "==> Gerando ISO bootável..."
sudo grub-mkrescue -o "$OUTPUT/$ISO_NAME" "$ISO_ROOT" -- -volid "NEXILIUMOS"

echo "==> ISO gerado:"
ls -lh "$OUTPUT/$ISO_NAME"
echo "==> Build concluído!"
