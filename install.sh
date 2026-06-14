#!/bin/bash
set -euo pipefail

# ===== VÉRIFICATIONS =====
[ "$EUID" -ne 0 ] && { echo "❌ Exécute en root !"; exit 1; }
[ ! -f /etc/void-release ] && { echo "❌ Live CD Void requis"; exit 1; }

# ===== CONFIG =====
REPO="https://mirrors.servercentral.com/voidlinux/current/"
EFI_SIZE="1G"; BOOT_SIZE="1G"
BTRFS_OPTS="rw,noatime,compress=zstd,discard=async"
DEFAULT_TIMEZONE="America/Montreal"
DEFAULT_HOSTNAME="VoidLinux"
DEFAULT_USER="voiduser"

# ===== FONCTIONS =====
print_title() { echo -e "\n===== $1 =====\n"; }
confirm() { read -p "$1 [O/n] " -n 1 -r; echo; [[ ! $REPLY =~ ^[OoYy]$ ]] && return 1; return 0; }

# ===== SÉLECTION DISQUE =====
print_title "SÉLECTION DU DISQUE"
echo "Disques disponibles:"
select DISK in $(lsblk -d -n -o NAME | sort); do
  [ -n "$DISK" ] && DISK="/dev/$DISK" && break
done
echo "Disque: $DISK"
confirm "Confirmer ? TOUTES LES DONNÉES SERONT EFFACÉES !" || exit 1

# ===== TIMEZONE =====
print_title "TIMEZONE"
read -p "Timezone [$DEFAULT_TIMEZONE]: " TIMEZONE
TIMEZONE="${TIMEZONE:-$DEFAULT_TIMEZONE}"

# ===== CONFIG SYSTÈME =====
print_title "CONFIGURATION"
read -p "Hostname [$DEFAULT_HOSTNAME]: " HOSTNAME
HOSTNAME="${HOSTNAME:-$DEFAULT_HOSTNAME}"
read -p "Utilisateur [$DEFAULT_USER]: " USERNAME
USERNAME="${USERNAME:-$DEFAULT_USER}"

# ===== MOTS DE PASSE =====
print_title "MOTS DE PASSE"
while true; do
  read -sp "Mot de passe root: " pwd1; echo
  read -sp "Confirmer: " pwd2; echo
  [ "$pwd1" = "$pwd2" ] && [ -n "$pwd1" ] && { ROOT_PWD="$pwd1"; break; } || echo "❌ Erreur"
done
while true; do
  read -sp "Mot de passe $USERNAME: " pwd1; echo
  read -sp "Confirmer: " pwd2; echo
  [ "$pwd1" = "$pwd2" ] && [ -n "$pwd1" ] && { USER_PWD="$pwd1"; break; } || echo "❌ Erreur"
done

# ===== PARTITIONNEMENT =====
print_title "PARTITIONNEMENT (EFI+Boot+LUKS)"
sfdisk "$DISK" <<EOF
label: gpt
start=2048, size=+$EFI_SIZE, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
size=+$BOOT_SIZE, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
EOF
partprobe "$DISK" 2>/dev/null; sleep 2
EFI_PART="${DISK}1"; BOOT_PART="${DISK}2"; ROOT_PART="${DISK}3"

# ===== CHIFFREMENT =====
print_title "CHIFFREMENT LUKS"
echo -e "$ROOT_PWD\n$ROOT_PWD" | cryptsetup luksFormat --type luks1 -y "$ROOT_PART" -
echo "$ROOT_PWD" | cryptsetup open "$ROOT_PART" cryptroot -
mkfs.fat -F32 -n EFI "$EFI_PART"
mkfs.ext2 -L grub "$BOOT_PART"
mkfs.btrfs -L Void /dev/mapper/cryptroot

# ===== MONTAGE =====
print_title "MONTAGE"
mount -o "$BTRFS_OPTS" /dev/mapper/cryptroot /mnt
btrfs subvolume create /mnt/{@,@home,@snapshots}
umount /mnt
mount -o "$BTRFS_OPTS,subvol=@" /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{home,.snapshots,var/cache,efi,boot}
btrfs subvolume create /mnt/var/cache/xbps /mnt/var/tmp /mnt/srv
mount -o rw,noatime "$EFI_PART" /mnt/efi
mount -o rw,noatime "$BOOT_PART" /mnt/boot

# ===== INSTALLATION =====
print_title "INSTALLATION"
mkdir -p /mnt/var/db/xbps/keys
cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/ 2>/dev/null || true
XBPS_ARCH="x86_64" xbps-install -S -R "$REPO" -r /mnt base-system linux-mainline btrfs-progs cryptsetup vim sudo

# ===== CHROOT =====
print_title "CONFIGURATION (CHROOT)"
for dir in dev proc sys run; do mount --rbind /$dir /mnt/$dir; mount --make-rslave /mnt/$dir; done
cp /etc/resolv.conf /mnt/etc/ 2>/dev/null || true
chroot /mnt /bin/bash <<EOF
# Timezone + Locale
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
sed -i "s/#$LOCALE/$LOCALE/" /etc/default/libc-locales
xbps-reconfigure -f glibc-locales 2>/dev/null || true

# Hostname
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1 localhost
::1 localhost
127.0.1.1 $HOSTNAME.localdomain $HOSTNAME
HOSTS

# Utilisateurs
echo "root:$ROOT_PWD" | chpasswd
useradd -m -G wheel -s /bin/bash "$USERNAME"
echo "$USERNAME:$USER_PWD" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers

# Dépôts
xbps-install -S
xbps-install -y void-repo-nonfree void-repo-multilib 2>/dev/null || true
xbps-install -S

# fstab
EFI_UUID=\\$(blkid -s UUID -o value "$EFI_PART")
BOOT_UUID=\\$(blkid -s UUID -o value "$BOOT_PART")
ROOT_UUID=\\$(blkid -s UUID -o value /dev/mapper/cryptroot)
cat > /etc/fstab <<FSTAB
UUID=$ROOT_UUID / btrfs $BTRFS_OPTS,subvol=@ 0 1
UUID=$ROOT_UUID /home btrfs $BTRFS_OPTS,subvol=@home 0 2
UUID=$ROOT_UUID /.snapshots btrfs $BTRFS_OPTS,subvol=@snapshots 0 2
UUID=$BOOT_UUID /boot ext2 defaults,noatime 0 2
UUID=$EFI_UUID /efi vfat defaults,noatime 0 2
tmpfs /tmp tmpfs defaults,nosuid,nodev 0 0
FSTAB

# GRUB
echo "GRUB_ENABLE_CRYPTODISK=y" >> /etc/default/grub
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=\"\"/GRUB_CMDLINE_LINUX_DEFAULT=\"loglevel=4 rd.auto=1 rd.luks.allow-discards\"/' /etc/default/grub
xbps-install -y grub-x86_64-efi
grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id="Void"

# Services
ln -s /etc/sv/dhcpcd /var/service/
ln -s /etc/sv/NetworkManager /var/service/
xbps-reconfigure -fa 2>/dev/null || true
xbps-install -y git NetworkManager 2>/dev/null || true
EOF

# ===== FINALISATION =====
print_title "FINALISATION"
umount -R /mnt 2>/dev/null || true
cryptsetup close cryptroot 2>/dev/null || true
echo -e "\n✅ INSTALLATION TERMINÉE !\nRedémarre avec: reboot\n"
confirm "Redémarrer maintenant ?" && reboot