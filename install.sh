#!/bin/bash
set -eu

# ============================================
# VÉRIFICATIONS
# ============================================
[ "$EUID" -ne 0 ] && { echo "❌ Root requis !"; exit 1; }
[ ! -f /etc/os-release ] && { echo "❌ Live CD Void requis !"; exit 1; }
modprobe dm-crypt 2>/dev/null || true

# ============================================
# CONFIG
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

# Cleanup function to run on exit/error
cleanup() {
  echo -e "\n🔄 Nettoyage avant sortie..."
  umount -R /mnt 2>/dev/null || true
  cryptsetup close cryptroot 2>/dev/null || true
  rm -f "$LUKS_KEYFILE" 2>/dev/null || true
  echo "✅ Nettoyage terminé"
}

# Set trap for cleanup on exit or error
trap cleanup EXIT ERR

# ============================================
# 1. DISQUE
# ============================================
print_title "SÉLECTION DU DISQUE"
echo "Disques disponibles :"
DISK=""
select opt in $(lsblk -d -n -o NAME | sort); do
  [ -n "$opt" ] && DISK="/dev/$opt" && break
done
[ -z "$DISK" ] && { echo "❌ Aucun disque"; exit 1; }
echo "Disque : $DISK"
confirm "Confirmer ? TOUTES LES DONNÉES SERONT EFFACÉES !" || exit 1

# ============================================
# 2. TIMEZONE
# ============================================
print_title "TIMEZONE"
DEFAULT_TIMEZONE="America/Montreal"
read -p "Timezone [$DEFAULT_TIMEZONE] : " TIMEZONE
TIMEZONE="${TIMEZONE:-$DEFAULT_TIMEZONE}"
timedatectl list-timezones 2>/dev/null | grep -q "^$TIMEZONE$" || {
  echo "⚠️  '$TIMEZONE' introuvable. Utilisation de $DEFAULT_TIMEZONE"
  TIMEZONE="$DEFAULT_TIMEZONE"
}

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
  while true; do
    read -sp "Mot de passe root : " pwd1
    echo
    read -sp "Confirmer : " pwd2
    echo
    [ "$pwd1" = "$pwd2" ] && [ -n "$pwd1" ] && { ROOT_PWD="$pwd1"; break; }
    echo "❌ Erreur"
  done

  while true; do
    read -sp "Mot de passe LUKS : " pwd1
    echo
    read -sp "Confirmer : " pwd2
    echo
    [ "$pwd1" = "$pwd2" ] && [ -n "$pwd1" ] && { LUKS_PWD="$pwd1"; break; }
    echo "❌ Erreur"
  done

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

sfdisk --force "$DISK" <<EOF
label: gpt
start=2048, size=+$EFI_SIZE, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name=EFI
size=+$BOOT_SIZE, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name=Boot
type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name=Root
EOF

partprobe "$DISK" 2>/dev/null || true
udevadm settle --timeout=5 2>/dev/null || sleep 3

if [ -e "${DISK}p1" ]; then
  EFI_PART="${DISK}p1"; BOOT_PART="${DISK}p2"; ROOT_PART="${DISK}p3"
elif [ -e "${DISK}1" ]; then
  EFI_PART="${DISK}1"; BOOT_PART="${DISK}2"; ROOT_PART="${DISK}3"
else
  echo "❌ Partitions introuvables !"; lsblk "$DISK"; exit 1
fi

[ ! -b "$EFI_PART" ] && { echo "❌ $EFI_PART introuvable !"; exit 1; }
[ ! -b "$BOOT_PART" ] && { echo "❌ $BOOT_PART introuvable !"; exit 1; }
[ ! -b "$ROOT_PART" ] && { echo "❌ $ROOT_PART introuvable !"; exit 1; }

# ============================================
# 6. CHIFFREMENT LUKS (VERSION ULTIME - FICHIER TEMPORAIRE)
# ============================================
print_title "CHIFFREMENT LUKS"

# Nettoyage si signature existante
if cryptsetup isLuks "$ROOT_PART" 2>/dev/null; then
  confirm "Signature LUKS existante. EFFACER ? (TOUTES LES DONNÉES PERDUES) !" || exit 1
  yes YES | cryptsetup erase "$ROOT_PART" || exit 1
  sleep 2
fi

# CRÉATION D'UN FICHIER TEMPORAIRE SÉCURISÉ
LUKS_KEYFILE=$(mktemp -p /tmp)
echo "$LUKS_PWD" > "$LUKS_KEYFILE"
chmod 600 "$LUKS_KEYFILE"

print_step "Chiffrement de $ROOT_PART..."
cryptsetup luksFormat --type luks1 --key-file "$LUKS_KEYFILE" "$ROOT_PART" - || {
  rm -f "$LUKS_KEYFILE"
  echo "❌ Échec chiffrement LUKS !"
  exit 1
}

print_step "Ouverture du conteneur LUKS..."
cryptsetup open --key-file "$LUKS_KEYFILE" "$ROOT_PART" cryptroot || {
  rm -f "$LUKS_KEYFILE"
  echo "❌ Échec ouverture LUKS !"
  echo "Essaie manuellement avec --key-file"
  exit 1
}

print_step "Ajout du mot de passe LUKS..."
echo "$LUKS_PWD" | cryptsetup luksAddKey --key-file "$LUKS_KEYFILE" "$ROOT_PART" - || {
  echo "❌ Échec ajout mot de passe LUKS !"
  exit 1
}

rm -f "$LUKS_KEYFILE"
print_step "LUKS configuré avec succès."

# ============================================
# 7. FORMATAGE
# ============================================
print_title "FORMATAGE"
mkfs.fat -F32 -n EFI "$EFI_PART" || exit 1
mkfs.ext2 -L grub "$BOOT_PART" || exit 1
mkfs.btrfs -L Void /dev/mapper/cryptroot || exit 1

# ============================================
# 8. MONTAGE
# ============================================
print_title "MONTAGE"
mount -o "$BTRFS_OPTS" /dev/mapper/cryptroot /mnt || exit 1

btrfs subvolume create /mnt/@ || exit 1
btrfs subvolume create /mnt/@home || exit 1
btrfs subvolume create /mnt/@snapshots || exit 1

umount /mnt || true
mount -o "$BTRFS_OPTS,subvol=@" /dev/mapper/cryptroot /mnt || exit 1

mkdir -p /mnt/{home,.snapshots,var/cache,efi,boot} || exit 1
btrfs subvolume create /mnt/var/cache/xbps || exit 1
btrfs subvolume create /mnt/var/tmp || exit 1
btrfs subvolume create /mnt/srv || exit 1

mount -o rw,noatime "$EFI_PART" /mnt/efi || exit 1
mount -o rw,noatime "$BOOT_PART" /mnt/boot || exit 1

# ============================================
# 9. INSTALLATION
# ============================================
print_title "INSTALLATION"
mkdir -p /mnt/var/db/xbps/keys
cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/ 2>/dev/null || true
XBPS_ARCH="$ARCH" xbps-install -S -R "$REPO" -r /mnt base-system linux-mainline btrfs-progs cryptsetup vim sudo || exit 1

# ============================================
# 10. CHROOT
# ============================================
print_title "CONFIGURATION (CHROOT)"
for dir in dev proc sys run; do
  mount --rbind /$dir /mnt/$dir
  mount --make-rslave /mnt/$dir
done
cp /etc/resolv.conf /mnt/etc/ 2>/dev/null || true

export TIMEZONE HOSTNAME USERNAME LOCALE ROOT_PWD USER_PWD LUKS_PWD EFI_PART BOOT_PART BTRFS_OPTS

chroot /mnt /bin/bash <<'CHROOT_EOF'
ln -sf /usr/share/zoneinfo/"$TIMEZONE" /etc/localtime
sed -i "s|#$LOCALE|$LOCALE|" /etc/default/libc-locales
xbps-reconfigure -f glibc-locales 2>/dev/null || true

echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<HOSTSEOF
127.0.0.1        localhost
::1              localhost
127.0.1.1        $HOSTNAME.localdomain $HOSTNAME
HOSTSEOF

echo "root:$ROOT_PWD" | chpasswd
useradd -m -G wheel -s /bin/bash "$USERNAME"
echo "$USERNAME:$USER_PWD" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers

xbps-install -S
xbps-install -y void-repo-nonfree 2>/dev/null || true
xbps-install -S
xbps-install -y void-repo-multilib 2>/dev/null || true
xbps-install -S

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

# Configure crypttab for LUKS
ROOT_PART_UUID=$(blkid -s UUID -o value "$ROOT_PART")
cat > /etc/crypttab <<CRYPTABEOF
cryptroot UUID=$ROOT_PART_UUID none luks
CRYPTABEOF

echo "GRUB_ENABLE_CRYPTODISK=y" >> /etc/default/grub
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=""/GRUB_CMDLINE_LINUX_DEFAULT="loglevel=4 rd.auto=1 rd.luks.allow-discards"/' /etc/default/grub
xbps-install -y grub-x86_64-efi 2>/dev/null || true
grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id="Void" 2>/dev/null || exit 1

echo "hostonly=yes" >> /etc/dracut.conf
ln -s /etc/sv/dhcpcd /var/service/ 2>/dev/null || true
ln -s /etc/sv/NetworkManager /var/service/ 2>/dev/null || true
xbps-reconfigure -fa 2>/dev/null || true
xbps-install -y git NetworkManager 2>/dev/null || true
CHROOT_EOF

# ============================================
# 11. FINALISATION
# ============================================
print_title "FINALISATION"

echo -e "\n✅ INSTALLATION TERMINÉE ! Redémarre avec: reboot\n"
confirm "Redémarrer maintenant ?" && reboot