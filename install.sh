#!/bin/bash
set -eu

# ============================================
# VÉRIFICATIONS
# ============================================
[ "$EUID" -ne 0 ] && { echo "❌ Root requis !"; exit 1; }
[ ! -f /etc/os-release ] && { echo "❌ Live CD Void requis !"; exit 1; }

# ============================================
# CONFIGURATION
# ============================================
REPO="https://mirrors.servercentral.com/voidlinux/current/"
ARCH="x86_64"
LOCALE="en_US.UTF-8"
DEFAULT_HOSTNAME="VoidLinux"
DEFAULT_USER="voiduser"
EFI_SIZE="1G"
BOOT_SIZE="1G"
BTRFS_OPTS="rw,noatime,compress=zstd,discard=async"

# ============================================
# FONCTIONS
# ============================================
print_title()  { echo -e "\n===== $1 =====\n"; }
print_step()   { echo "→ $1"; }
confirm() {
  read -p "$1 [O/n] " -n 1 -r
  echo
  [[ ! $REPLY =~ ^[OoYy]$ ]] && return 1
  return 0
}

# ============================================
# 1. SÉLECTION DISQUE
# ============================================
print_title "SÉLECTION DU DISQUE"
echo "Disques disponibles :"
DISK=""
select opt in $(lsblk -d -n -o NAME | sort); do
  [ -n "$opt" ] && DISK="/dev/$opt" && break
done
[ -z "$DISK" ] && { echo "❌ Aucun disque sélectionné"; exit 1; }
echo "Disque : $DISK"
confirm "Confirmer ? TOUTES LES DONNÉES SERONT EFFACÉES !" || exit 1

# ============================================
# 2. TIMEZONE
# ============================================
print_title "TIMEZONE"
DEFAULT_TIMEZONE="America/Montreal"
read -p "Timezone [$DEFAULT_TIMEZONE] : " TIMEZONE
TIMEZONE="${TIMEZONE:-$DEFAULT_TIMEZONE}"
if ! timedatectl list-timezones 2>/dev/null | grep -q "^$TIMEZONE$"; then
  echo "⚠️ '$TIMEZONE' introuvable. Utilisation de $DEFAULT_TIMEZONE"
  TIMEZONE="$DEFAULT_TIMEZONE"
fi

# ============================================
# 3. CONFIG SYSTÈME
# ============================================
print_title "CONFIGURATION"
read -p "Hostname [$DEFAULT_HOSTNAME] : " HOSTNAME
HOSTNAME="${HOSTNAME:-$DEFAULT_HOSTNAME}"
read -p "Utilisateur [$DEFAULT_USER] : " USERNAME
USERNAME="${USERNAME:-$DEFAULT_USER}"

# ============================================
# 4. MOTS DE PASSE
# ============================================
print_title "MOTS DE PASSE"
read -p "Un seul mot de passe pour tout ? [O/n] " -n 1 -r
echo
if [[ $REPLY =~ ^[OoYy]$ ]]; then
  while true; do
    read -sp "Mot de passe (root + LUKS + $USERNAME) : " pwd1
    echo
    read -sp "Confirmer : " pwd2
    echo
    [ "$pwd1" = "$pwd2" ] && [ -n "$pwd1" ] && {
      ROOT_PWD="$pwd1"
      LUKS_PWD="$pwd1"
      USER_PWD="$pwd1"
      break
    }
    echo "❌ Erreur"
  done
else
  # Mot de passe root
  while true; do
    read -sp "Mot de passe root : " pwd1
    echo
    read -sp "Confirmer : " pwd2
    echo
    [ "$pwd1" = "$pwd2" ] && [ -n "$pwd1" ] && { ROOT_PWD="$pwd1"; break; }
    echo "❌ Erreur"
  done

  # Mot de passe LUKS
  while true; do
    read -sp "Mot de passe LUKS : " pwd1
    echo
    read -sp "Confirmer : " pwd2
    echo
    [ "$pwd1" = "$pwd2" ] && [ -n "$pwd1" ] && { LUKS_PWD="$pwd1"; break; }
    echo "❌ Erreur"
  done

  # Mot de passe utilisateur
  while true; do
    read -sp "Mot de passe $USERNAME : " pwd1
    echo
    read -sp "Confirmer : " pwd2
    echo
    [ "$pwd1" = "$pwd2" ] && [ -n "$pwd1" ] && { USER_PWD="$pwd1"; break; }
    echo "❌ Erreur"
  done
fi

# ============================================
# 5. PARTITIONNEMENT
# ============================================
print_title "PARTITIONNEMENT"
echo "  - EFI ($EFI_SIZE, FAT32)"
echo "  - Boot ($BOOT_SIZE, ext2)"
echo "  - Racine (LUKS + BTRFS)"
confirm "Continuer ?" || exit 1

# Création des partitions
parted -s "$DISK" mklabel gpt
sfdisk "$DISK" <<EOF
label: gpt
start=2048, size=+$EFI_SIZE, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name=EFI
size=+$BOOT_SIZE, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name=Boot
type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name=Root
EOF
partprobe "$DISK" 2>/dev/null || true
sleep 2

# Détection du format (nvme vs sda)
if lsblk "$DISK" | grep -q "${DISK}p1"; then
  EFI_PART="${DISK}p1"
  BOOT_PART="${DISK}p2"
  ROOT_PART="${DISK}p3"
else
  EFI_PART="${DISK}1"
  BOOT_PART="${DISK}2"
  ROOT_PART="${DISK}3"
fi

# ============================================
# 6. CHIFFREMENT LUKS
# ============================================
print_title "CHIFFREMENT LUKS"
echo -e "$LUKS_PWD\\n$LUKS_PWD" | cryptsetup luksFormat --type luks1 -y "$ROOT_PART" -
echo "$LUKS_PWD" | cryptsetup open "$ROOT_PART" cryptroot -
mkfs.fat -F32 -n EFI "$EFI_PART"
mkfs.ext2 -L grub "$BOOT_PART"
mkfs.btrfs -L Void /dev/mapper/cryptroot

# ============================================
# 7. MONTAGE
# ============================================
print_title "MONTAGE"
mount -o "$BTRFS_OPTS" /dev/mapper/cryptroot /mnt

# Création des subvolumes (CORRIGÉ : un par un)
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots

umount /mnt
mount -o "$BTRFS_OPTS,subvol=@" /dev/mapper/cryptroot /mnt

# Répertoires et subvolumes supplémentaires
mkdir -p /mnt/{home,.snapshots,var/cache}
btrfs subvolume create /mnt/var/cache/xbps
btrfs subvolume create /mnt/var/tmp
btrfs subvolume create /mnt/srv

# Montage EFI et Boot
mkdir -p /mnt/{efi,boot}
mount -o rw,noatime "$EFI_PART" /mnt/efi
mount -o rw,noatime "$BOOT_PART" /mnt/boot

# ============================================
# 8. INSTALLATION
# ============================================
print_title "INSTALLATION"
mkdir -p /mnt/var/db/xbps/keys
cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/ 2>/dev/null || true
XBPS_ARCH="$ARCH" xbps-install -S -R "$REPO" -r /mnt base-system linux-mainline btrfs-progs cryptsetup vim sudo

# ============================================
# 9. CHROOT (CORRIGÉ : export des variables)
# ============================================
print_title "CONFIGURATION (CHROOT)"
for dir in dev proc sys run; do
  mount --rbind /$dir /mnt/$dir
  mount --make-rslave /mnt/$dir
done
cp /etc/resolv.conf /mnt/etc/ 2>/dev/null || true

# Export des variables pour le chroot
export TIMEZONE HOSTNAME USERNAME LOCALE ROOT_PWD USER_PWD LUKS_PWD EFI_PART BOOT_PART BTRFS_OPTS

chroot /mnt /bin/bash <<'CHROOT_EOF'
# Timezone et Locale (CORRIGÉ : délimiteur | pour sed)
ln -sf /usr/share/zoneinfo/"$TIMEZONE" /etc/localtime
sed -i "s|#$LOCALE|$LOCALE|" /etc/default/libc-locales
xbps-reconfigure -f glibc-locales 2>/dev/null || true

# Hostname
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<HOSTSEOF
127.0.0.1        localhost
::1              localhost
127.0.1.1        $HOSTNAME.localdomain $HOSTNAME
HOSTSEOF

# Utilisateurs
echo "root:$ROOT_PWD" | chpasswd
useradd -m -G wheel -s /bin/bash "$USERNAME"
echo "$USERNAME:$USER_PWD" | chpasswd

# Sudo
echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers

# Dépôts
xbps-install -S
xbps-install -y void-repo-nonfree 2>/dev/null || true
xbps-install -S
xbps-install -y void-repo-multilib 2>/dev/null || true
xbps-install -S

# fstab
EFI_UUID=$(blkid -s UUID -o value "$EFI_PART")
BOOT_UUID=$(blkid -s UUID -o value "$BOOT_PART")
ROOT_UUID=$(blkid -s UUID -o value /dev/mapper/cryptroot)
cat > /etc/fstab <<FSTABEOF
UUID=$ROOT_UUID / btrfs $BTRFS_OPTS,subvol=@ 0 1
UUID=$ROOT_UUID /home btrfs $BTRFS_OPTS,subvol=@home 0 2
UUID=$ROOT_UUID /.snapshots btrfs $BTRFS_OPTS,subvol=@snapshots 0 2
UUID=$BOOT_UUID /boot ext2 defaults,noatime 0 2
UUID=$EFI_UUID /efi vfat defaults,noatime 0 2
tmpfs /tmp tmpfs defaults,nosuid,nodev 0 0
FSTABEOF

# GRUB
echo "GRUB_ENABLE_CRYPTODISK=y" >> /etc/default/grub
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=""/GRUB_CMDLINE_LINUX_DEFAULT="loglevel=4 rd.auto=1 rd.luks.allow-discards"/' /etc/default/grub
xbps-install -y grub-x86_64-efi 2>/dev/null || true
grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id="Void" 2>/dev/null || true

# Services
echo "hostonly=yes" >> /etc/dracut.conf
ln -s /etc/sv/dhcpcd /var/service/ 2>/dev/null || true
ln -s /etc/sv/NetworkManager /var/service/ 2>/dev/null || true
xbps-reconfigure -fa 2>/dev/null || true
xbps-install -y git NetworkManager 2>/dev/null || true
CHROOT_EOF

# ============================================
# 10. FINALISATION
# ============================================
print_title "FINALISATION"
umount -R /mnt 2>/dev/null || true
cryptsetup close cryptroot 2>/dev/null || true
echo -e "\n✅ INSTALLATION TERMINÉE ! Redémarre avec: reboot\n"
read -p "Redémarrer maintenant ? [O/n] " -n 1 -r
echo
[[ $REPLY =~ ^[OoYy]$ ]] && reboot