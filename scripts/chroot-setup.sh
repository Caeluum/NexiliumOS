#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "nexiliumos" > /etc/hostname

cat > /etc/hosts << 'HOSTS'
127.0.0.1   localhost
127.0.1.1   nexiliumos
HOSTS

apt-get update

echo "==> Carregando lista de pacotes..."
# shellcheck source=packages.list
source /tmp/packages.list

echo "==> Instalando todos os pacotes do NexiliumOS (${#PACKAGES[@]} pacotes)..."
apt-get install -y "${PACKAGES[@]}"

echo "==> Removendo o gdm3 (não usamos mais — sid o entrelaçou com o gnome-shell)..."
# gdm3 não é instalado a essa altura (trocamos por sddm no packages.list),
# mas o task-kde-desktop pode puxar alguma dependência que sugira ele.
# Purga defensiva, sem quebrar o build se ele nem estiver presente.
apt-get purge -y gdm3 2>/dev/null || true

echo "==> Removendo calamares-settings-debian e aplicando nossa config do Calamares..."
# Esse pacote briga com nossos arquivos em /etc/calamares (o post-install
# dele espera gerenciar settings.conf/branding sozinho). Purga ele e só
# então copia nossa config, garantindo que não sobra nada do branding
# padrão do Debian por cima.
apt-get purge -y calamares-settings-debian 2>/dev/null || true
rm -rf /etc/calamares
mkdir -p /etc/calamares
if [ -d /tmp/calamares-config ]; then
    cp -r /tmp/calamares-config/. /etc/calamares/
    rm -rf /tmp/calamares-config
else
    echo "AVISO: /tmp/calamares-config não encontrado, Calamares ficará com config incompleta." >&2
fi

echo "==> Gerando locales (sem isso o KDE/SDDM podem crashar ao subir a sessão)..."
sed -i 's/^# *\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
sed -i 's/^# *\(pt_BR.UTF-8 UTF-8\)/\1/' /etc/locale.gen
if ! grep -q "^en_US.UTF-8 UTF-8" /etc/locale.gen; then
    echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
fi
if ! grep -q "^pt_BR.UTF-8 UTF-8" /etc/locale.gen; then
    echo "pt_BR.UTF-8 UTF-8" >> /etc/locale.gen
fi
locale-gen
update-locale LANG=en_US.UTF-8 LANGUAGE=en_US:en

echo "==> Criando launcher que pergunta offline/online antes do Calamares (estilo Artix)..."
# Em vez de abrir o Calamares direto, o atalho chama esse wrapper. Ele
# mostra um diálogo simples (kdialog, já que o live é sempre KDE) com
# as duas opções e escolhe qual settings.conf carregar: o online (com
# a página de troca de DE via netinstall) ou o offline (sem ela, direto
# pro KDE Plasma do squashfs). Isso evita de vez a página do netinstall
# aparecer desabilitada quando não há internet — nesse modo ela nem
# existe na sequência.
cat > /usr/local/bin/nexiliumos-installer << 'INSTALLER_LAUNCHER'
#!/usr/bin/env bash
set -uo pipefail

CHOICE="$(kdialog --menu "Selecione o método de instalação do NexiliumOS:" \
    offline "Offline (usa o KDE Plasma que já vem pronto na imagem)" \
    online  "Online (baixa a lista de pacotes e permite escolher outro ambiente desktop)")"

# kdialog retorna código != 0 se a pessoa cancelar/fechar o diálogo.
if [ $? -ne 0 ] || [ -z "$CHOICE" ]; then
    exit 0
fi

case "$CHOICE" in
    offline) SETTINGS="/etc/calamares/settings-offline.conf" ;;
    online)  SETTINGS="/etc/calamares/settings-online.conf" ;;
    *)       exit 1 ;;
esac

exec pkexec calamares -c "$SETTINGS"
INSTALLER_LAUNCHER
chmod +x /usr/local/bin/nexiliumos-installer

echo "==> Criando atalho do instalador na área de trabalho..."
mkdir -p /etc/skel/Desktop
if [ -f /usr/share/applications/calamares.desktop ]; then
    cp /usr/share/applications/calamares.desktop /etc/skel/Desktop/calamares.desktop
    # Troca o nome exibido no ícone/menu de "Install Debian" pra
    # "Install NexiliumOS" (o pacote calamares do Debian traz esse Name=
    # hardcoded no .desktop; sobrescrevemos aqui). Troca também o Exec=
    # pro nosso launcher, em vez de chamar o calamares direto — é ele
    # quem decide (via pkexec) qual settings.conf abrir depois da
    # escolha offline/online.
    sed -i 's/^Name=.*/Name=Install NexiliumOS/' /etc/skel/Desktop/calamares.desktop
    sed -i '/^Name\[.*\]=/d' /etc/skel/Desktop/calamares.desktop
    sed -i 's#^Exec=.*#Exec=/usr/local/bin/nexiliumos-installer#' /etc/skel/Desktop/calamares.desktop
    chmod +x /etc/skel/Desktop/calamares.desktop
    # Faz o mesmo no launcher do menu de aplicativos, não só no atalho da área de trabalho
    sed -i 's/^Name=.*/Name=Install NexiliumOS/' /usr/share/applications/calamares.desktop
    sed -i '/^Name\[.*\]=/d' /usr/share/applications/calamares.desktop
    sed -i 's#^Exec=.*#Exec=/usr/local/bin/nexiliumos-installer#' /usr/share/applications/calamares.desktop
fi

echo "==> Instalando script de wallpaper (roda no primeiro login, detecta o DE)..."
# Esse script cobre todo mundo que pode acabar no sistema final: o KDE
# Plasma que já vem pronto no squashfs, E qualquer um dos outros DEs
# escolhidos via netinstall.yaml no instalador online (que só existem
# depois da instalação, não no momento do build). Por isso ele roda via
# autostart no primeiro login em vez de ser configurado estaticamente
# aqui — nesse ponto do build ainda não sabemos qual DE a pessoa vai
# escolher.
cat > /usr/local/bin/nexiliumos-wallpaper.sh << 'WALLPAPER_SCRIPT'
#!/usr/bin/env bash
# NexiliumOS - aplica o wallpaper padrão no ambiente desktop detectado.
# Roda uma vez no primeiro login; a entrada de autostart se remove
# sozinha no final pra não sobrescrever wallpaper trocado pelo usuário
# depois.
set -uo pipefail

WALLPAPER="/usr/share/backgrounds/nexiliumos/sla.png"
DE="${XDG_CURRENT_DESKTOP:-${DESKTOP_SESSION:-}}"
DE_LOWER="$(echo "$DE" | tr '[:upper:]' '[:lower:]')"

case "$DE_LOWER" in
    *kde*|*plasma*)
        command -v plasma-apply-wallpaperimage >/dev/null 2>&1 && \
            plasma-apply-wallpaperimage "$WALLPAPER"
        ;;
    *cinnamon*)
        command -v gsettings >/dev/null 2>&1 && \
            gsettings set org.cinnamon.desktop.background picture-uri "file://$WALLPAPER"
        ;;
    *mate*)
        command -v gsettings >/dev/null 2>&1 && \
            gsettings set org.mate.background picture-filename "$WALLPAPER"
        ;;
    *xfce*)
        if command -v xfconf-query >/dev/null 2>&1; then
            for prop in $(xfconf-query -c xfce4-desktop -l 2>/dev/null | grep last-image); do
                xfconf-query -c xfce4-desktop -p "$prop" -s "$WALLPAPER"
            done
        fi
        ;;
    *lxqt*)
        command -v pcmanfm-qt >/dev/null 2>&1 && \
            pcmanfm-qt --set-wallpaper="$WALLPAPER" 2>/dev/null
        ;;
    *lxde*)
        command -v pcmanfm >/dev/null 2>&1 && \
            pcmanfm --set-wallpaper="$WALLPAPER" 2>/dev/null
        ;;
    *gnome*|*budgie*|*unity*|*)
        # Fallback pro schema do GNOME: cobre GNOME e Budgie (que usa o
        # mesmo backend gsettings), e serve de default genérico caso
        # XDG_CURRENT_DESKTOP não seja reconhecido acima.
        command -v gsettings >/dev/null 2>&1 && {
            gsettings set org.gnome.desktop.background picture-uri "file://$WALLPAPER"
            gsettings set org.gnome.desktop.background picture-uri-dark "file://$WALLPAPER" 2>/dev/null || true
        }
        ;;
esac

rm -f "$HOME/.config/autostart/nexiliumos-wallpaper.desktop"
WALLPAPER_SCRIPT
chmod +x /usr/local/bin/nexiliumos-wallpaper.sh

mkdir -p /etc/skel/.config/autostart
cat > /etc/skel/.config/autostart/nexiliumos-wallpaper.desktop << 'AUTOSTART'
[Desktop Entry]
Type=Application
Name=NexiliumOS Wallpaper
Exec=/usr/local/bin/nexiliumos-wallpaper.sh
X-GNOME-Autostart-enabled=true
NoDisplay=true
AUTOSTART

echo "==> Liberando o Calamares sem pedir senha (usuários do grupo sudo)..."
mkdir -p /etc/polkit-1/rules.d
cat > /etc/polkit-1/rules.d/45-nexilium-calamares.rules << 'POLKIT'
polkit.addRule(function(action, subject) {
    if (!subject.isInGroup("sudo")) {
        return polkit.Result.NOT_HANDLED;
    }

    // Caso 1: pkexec genérico chamando o binário do calamares diretamente.
    if (action.id == "org.freedesktop.policykit.exec" &&
        action.lookup("program") &&
        action.lookup("program").indexOf("calamares") !== -1) {
        return polkit.Result.YES;
    }

    // Caso 2: ação de polkit dedicada registrada pelo próprio pacote
    // calamares (ex: org.calamares.calamares.pkexec.run ou variante
    // debianizada). O .desktop do pacote calamares "puro" (diferente do
    // calamares-settings-debian, que a gente purga) costuma usar um
    // wrapper que dispara uma ação com ID próprio em vez de pkexec
    // genérico — a regra do Caso 1 sozinha não cobre isso.
    if (action.id.toLowerCase().indexOf("calamares") !== -1) {
        return polkit.Result.YES;
    }

    return polkit.Result.NOT_HANDLED;
});
POLKIT

echo "==> Criando usuário liveuser..."
useradd -m -s /bin/bash liveuser
echo "liveuser:live" | chpasswd
usermod -aG sudo,audio,video,plugdev liveuser

echo "==> Habilitando login sem senha para liveuser via PAM (grupo nopasswdlogin)..."
# IMPORTANTE: ao contrário do Ubuntu, o Debian NÃO reconhece o grupo
# "nopasswdlogin" nativamente. Sem essa regra no PAM do SDDM, o AutomaticLogin
# ainda funciona para o primeiro boot, mas qualquer prompt de senha do SDDM
# (troca de usuário, tela de bloqueio, etc.) continuaria pedindo senha
# mesmo com o usuário no grupo. Por isso adicionamos a regra manualmente.
groupadd -f nopasswdlogin
usermod -aG nopasswdlogin liveuser

# Nomes de arquivo PAM variam entre versões do pacote sddm no Debian
# (às vezes usa um serviço dedicado "sddm-autologin", às vezes reaproveita
# o "sddm" genérico pra tudo) — cobrimos as três possibilidades, cada
# uma só é tocada se existir.
for pamfile in sddm sddm-autologin sddm-greeter; do
    if [ -f "/etc/pam.d/${pamfile}" ] && ! grep -q "pam_succeed_if.so user ingroup nopasswdlogin" "/etc/pam.d/${pamfile}"; then
        sed -i '0,/^auth/s//auth\tsufficient\tpam_succeed_if.so user ingroup nopasswdlogin\nauth/' "/etc/pam.d/${pamfile}"
    fi
done

echo "==> Configurando autologin no SDDM..."
mkdir -p /etc/sddm.conf.d
cat > /etc/sddm.conf.d/autologin.conf << 'SDDMCONF'
[Autologin]
User=liveuser
Session=plasma.desktop
Relogin=false

[General]
Numlock=on
SDDMCONF

echo "==> Definindo sessão padrão do liveuser (Plasma Wayland, com fallback X11)..."
mkdir -p /var/lib/AccountsService/users
cat > /var/lib/AccountsService/users/liveuser << 'ACCOUNTS'
[User]
Session=plasma
XSession=plasmax11
SystemAccount=false
ACCOUNTS

echo "==> Habilitando serviços de boot..."
systemctl enable sddm.service

systemctl enable NetworkManager
systemctl enable accounts-daemon
systemctl enable dbus

echo "==> Identidade do sistema..."
cat > /etc/os-release << 'OSRELEASE'
NAME="NexiliumOS"
VERSION="1.0 (Sid)"
ID=nexiliumos
ID_LIKE=debian
PRETTY_NAME="NexiliumOS 1.0 (Sid)"
HOME_URL="https://github.com/zanfss0/NexiliumOS"
OSRELEASE

echo "==> Garantindo sources.list correto no live..."
cat > /etc/apt/sources.list << 'SOURCES'
deb http://deb.debian.org/debian sid main contrib non-free non-free-firmware
SOURCES

echo "==> Atualizando índice do apt (sources.list mudou, senão contrib/non-free-firmware não aparecem)..."
apt-get update

echo "==> Aceleração gráfica em VirtualBox: nada a instalar aqui (por enquanto)."
# ATUALIZAÇÃO (migração pro sid): os pacotes virtualbox-guest-utils /
# virtualbox-guest-x11 / virtualbox-guest-dkms JÁ EXISTEM no repositório
# sid — a restrição abaixo, que motivou não instalá-los, valia só pro
# Debian stable/trixie. Ou seja, essa limitação não existe mais; dá pra
# adicionar esses pacotes ao packages.list se quiser VBoxService completo
# (clipboard compartilhado, drag-and-drop, sincronismo de horário) em vez
# de só mouse integration/aceleração básica.
#
# Motivo original de não instalar (não se aplica mais no sid, mantido
# como contexto histórico):
# os pacotes NÃO existiam no Debian 13 (trixie) estável — só existiam no
# repositório "sid" (a Debian Wiki confirma: pacotes do VirtualBox não são
# oferecidos em stable por falta de suporte de segurança do upstream).
# Tentar instalá-los no trixie sempre falhava com "Unable to locate
# package" e derrubava o build inteiro.
#
# O kernel do Debian já traz embutidos os módulos vboxguest/vboxvideo/vboxsf
# (o pacote virtual "virtualbox-guest-modules" já é satisfeito pelo pacote
# linux-image-amd64 normal), então mouse integration e aceleração de vídeo
# básica em VM já funcionam sem pacote nenhum mesmo sem o VBoxService.

echo "==> Forçando target gráfico..."
systemctl set-default graphical.target

echo "==> Corrigindo machine-id (essencial para dbus/logind funcionarem no live-boot)..."
rm -f /etc/machine-id
touch /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -sf /etc/machine-id /var/lib/dbus/machine-id
# Deixa vazio de propósito: o live-boot/systemd gera um novo machine-id
# a cada boot da ISO. Se o arquivo não existisse (ou viesse copiado do
# host de build), dbus e systemd-logind falham silenciosamente e a
# sessão gráfica cai numa tela de erro logo após o login.

echo "==> Guardando cópia permanente da lista de pacotes no sistema..."
mkdir -p /etc/nexiliumos
cp /tmp/packages.list /etc/nexiliumos/packages.list
chmod 644 /etc/nexiliumos/packages.list

echo "==> Limpando..."
apt-get clean
apt-get autoremove -y
rm -rf /var/lib/apt/lists/*
rm -f /tmp/chroot-setup.sh /tmp/packages.list
