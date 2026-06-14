#!/bin/bash
set -eu

# ============================================
# VÉRIFICATIONS INITIALES
# ============================================
[ "$EUID" -ne 0 ] && { echo "❌ Root requis !"; exit 1; }
[ ! -f /etc/os-release ] && { echo "❌ Live CD Void Linux requis !"; exit 1; }

# Charger les modules noyau nécessaires
modprobe dm-crypt 2>/dev/null || true

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
echo "  - Partition 1 : EFI ($EFI_SIZE, FAT32)"
echo "  - Partition 2 : Boot ($BOOT_SIZE, ext2)"
echo "  - Partition 3 : Racine (LUKS + BTRFS)"
confirm "Continuer ?" || exit 1

print_step "Création des partitions avec sfdisk..."
sfdisk --force "$DISK" <<EOF
label: gpt
start=2048, size=+$EFI_SIZE, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name=EFI
size=+$BOOT_SIZE, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name=Boot
type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name=Root
EOF

# Synchronisation avec le noyau
print_step "Synchronisation des partitions..."
partprobe "$DISK" 2>/dev/null || true
udevadm settle --timeout=5 2>/dev/null || sleep 3

# Détection du format (nvme vs sda)
if [ -e "${DISK}p1" ]; then
  EFI_PART="${DISK}p1"
  BOOT_PART="${DISK}p2"
  ROOT_PART="${DISK}p3"
elif [ -e "${DISK}1" ]; then
  EFI_PART="${DISK}1"
  BOOT_PART="${DISK}2"
  ROOT_PART="${DISK}3"
else
  echo "❌ Impossible de détecter les partitions !"
  lsblk "$DISK"
  exit 1
fi

# Vérification ULTRA-ROBUSTE
[ ! -b "$EFI_PART" ] && { echo "❌ $EFI_PART introuvable !"; exit 1; }
[ ! -b "$BOOT_PART" ] && { echo "❌ $BOOT_PART introuvable !"; exit 1; }
[ ! -b "$ROOT_PART" ] && { echo "❌ $ROOT_PART introuvable !"; exit 1; }

print_step "Partitions détectées : $EFI_PART, $BOOT_PART, $ROOT_PART"

# ============================================
# 6. CHIFFREMENT LUKS (NOUVELLE VERSION AVEC NETTOYAGE)
# ============================================
print_title "CHIFFREMENT LUKS"

# VÉRIFICATION CRUCIALE : la partition a-t-elle déjà une signature LUKS ?
if cryptsetup isLuks "$ROOT_PART" 2>/dev/null; then
  print_step "⚠️  $ROOT_PART contient DÉJÀ une signature LUKS !"
  print_step "Cela vient probablement d'une tentative précédente."
  confirm "EFFACER la signature existante et recommencer ? (TOUTES LES DONNÉES SERONT PERDUES) !" || exit 1
  print_step "Nettoyage de la signature LUKS existante..."
  cryptsetup erase "$ROOT_PART" - || {
    echo "❌ Échec du nettoyage ! Essaie manuellement :"
    echo "  cryptsetup erase $ROOT_PART"
    exit 1
  }
  sleep 2
  print_step "Signature LUKS supprimée. Prêt pour le chiffrement."
fi

# Vérification finale
[ ! -b "$ROOT_PART" ] && { echo "❌ $ROOT_PART introuvable !"; exit 1; }

print_step "Chiffrement de $ROOT_PART (cela peut prendre du temps)..."
echo -e "$LUKS_PWD\\n$LUKS_PWD" | cryptsetup luksFormat --type luks1 --batch-mode "$ROOT_PART" - || {
  echo "❌ Échec du chiffrement LUKS !"
  echo "Solutions :"
  echo "  1. Vérifie que cryptsetup est installé : xbps-install -y cryptsetup"
  echo "  2. Essaie manuellement : cryptsetup luksFormat --batch-mode $ROOT_PART"
  echo "  3. Si la partition a une signature : cryptsetup erase $ROOT_PART"
  exit 1
}

print_step "Ouverture du conteneur LUKS..."
echo "$LUKS_PWD" | cryptsetup open "$ROOT_PART" cryptroot - || {
  echo "❌ Échec de l'ouverture LUKS !"
  echo "  - Mot de passe incorrect ?"
  echo "  - Partition corrompue ? Essaie : cryptsetup repair $ROOT_PART"
  exit 1
}

[ ! -e "/dev/mapper/cryptroot" ] && {
  echo "❌ /dev/mapper/cryptroot introuvable !"
  ls /dev/mapper/
  exit 1
}

print_step "Formatage des partitions..."
mkfs.fat -F32 -n EFI "$EFI_PART" || { echo "❌ Échec formatage EFI !"; exit 1; }
mkfs.ext2 -L grub "$BOOT_PART" || { echo "❌ Échec formatage Boot !"; exit 1; }
mkfs.btrfs -L Void /dev/mapper/cryptroot || { echo "❌ Échec formatage BTRFS !"; exit 1; }

# ============================================
# 7. MONTAGE
# ============================================
print_title "MONTAGE"
mount -o "$BTRFS_OPTS" /dev/mapper/cryptroot /mnt || { echo "❌ Échec montage racine !"; exit 1; }

btrfs subvolume create /mnt/@ || { echo "❌ Échec création @ !"; exit 1; }
btrfs subvolume create /mnt/@home || { echo "❌ Échec création @home !"; exit 1; }
btrfs subvolume create /mnt/@snapshots || { echo "❌ Échec création @snapshots !"; exit 1; }

umount /mnt || true
mount -o "$BTRFS_OPTS,subvol=@" /dev/mapper/cryptroot /mnt || { echo "❌ Échec remontage !"; exit 1; }

mkdir -p /mnt/{home,.snapshots,var/cache,efi,boot} || { echo "❌ Échec création répertoires !"; exit 1; }
btrfs subvolume create /mnt/var/cache/xbps || { echo "❌ Échec var/cache/xbps !"; exit 1; }
btrfs subvolume create /mnt/var/tmp || { echo "❌ Échec var/tmp !"; exit 1; }
btrfs subvolume create /mnt/srv || { echo "❌ Échec srv !"; exit 1; }

mount -o rw,noatime "$EFI_PART" /mnt/efi || { echo "❌ Échec montage EFI !"; exit 1; }
mount -o rw,noatime "$BOOT_PART" /mnt/boot || { echo "❌ Échec montage Boot !"; exit 1; }

print_step "Vérification des points de montage :"
df -h | grep /mnt

# ============================================
# 8. INSTALLATION
# ============================================
print_title "INSTALLATION DU SYSTÈME DE BASE"
mkdir -p /mnt/var/db/xbps/keys
cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/ 2>/dev/null || echo "⚠️ Aucune clé XBPS trouvée"

XBPS_ARCH="$ARCH" xbps-install -S -R "$REPO" -r /mnt base-system linux-mainline btrfs-progs cryptsetup vim sudo || {
  echo "❌ Échec installation des paquets !"
  echo "Vérifie ta connexion internet et le miroir : $REPO"
  exit 1
}

# ============================================
# 9. CHROOT
# ============================================
print_title "CONFIGURATION (CHROOT)"
for dir in dev proc sys run; do
  mount --rbind /$dir /mnt/$dir || { echo "❌ Échec mount --rbind /$dir !"; exit 1; }
  mount --make-rslave /mnt/$dir || { echo "❌ Échec mount --make-rslave !"; exit 1; }
done
cp /etc/resolv.conf /mnt/etc/ 2>/dev/null || echo "⚠️ /etc/resolv.conf introuvable"

export TIMEZONE HOSTNAME USERNAME LOCALE ROOT_PWD USER_PWD LUKS_PWD EFI_PART BOOT_PART BTRFS_OPTS

chroot /mnt /bin/bash <<'CHROOT_EOF'
# Timezone et Locale
ln -sf /usr/share/zoneinfo/"$TIMEZONE" /etc/localtime
sed -i "s|#$LOCALE|$LOCALE|" /etc/default/libc-locales
xbps-reconfigure -f glibc-locales 2>/dev/null || echo "⚠️ Erreur locale"

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
xbps-install -y void-repo-nonfree 2>/dev/null || echo "⚠️ nonfree introuvable"
xbps-install -S
xbps-install -y void-repo-multilib 2>/dev/null || echo "⚠️ multilib introuvable"
xbps-install -S

# intel-ucode
xbps-install -Su intel-ucode 2>/dev/null || echo "⚠️ intel-ucode introuvable"

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

# GRUB avec support LUKS
echo "GRUB_ENABLE_CRYPTODISK=y" >> /etc/default/grub
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=""/GRUB_CMDLINE_LINUX_DEFAULT="loglevel=4 rd.auto=1 rd.luks.allow-discards"/' /etc/default/grub
xbps-install -y grub-x86_64-efi 2>/dev/null || echo "⚠️ grub introuvable"
grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id="Void" 2>/dev/null || {
  echo "❌ Échec installation GRUB !"
  exit 1
}

# Services
echo "hostonly=yes" >> /etc/dracut.conf
ln -s /etc/sv/dhcpcd /var/service/ 2>/dev/null || echo "⚠️ dhcpcd introuvable"
ln -s /etc/sv/NetworkManager /var/service/ 2>/dev/null || echo "⚠️ NetworkManager introuvable"
xbps-reconfigure -fa 2>/dev/null || echo "⚠️ reconfig introuvable"
xbps-install -y git NetworkManager 2>/dev/null || echo "⚠️ git/NetworkManager introuvable"
CHROOT_EOF

# ============================================
# 10. FINALISATION
# ============================================
print_title "FINALISATION"
print_step "Démontage des partitions..."
umount -R /mnt 2>/dev/null || echo "⚠️ Avertissement démontage"

print_step "Fermeture du conteneur LUKS..."
cryptsetup close cryptroot 2>/dev/null || echo "⚠️ Avertissement fermeture LUKS"

echo -e "\n=========================================="
echo "  ✅ INSTALLATION TERMINÉE AVEC SUCCÈS !"
echo "=========================================="
echo ""
echo "  Pour démarrer :"
echo "  1. Redémarre : reboot"
echo "  2. Au boot, entre le mot de passe LUKS"
echo "  3. Connecte-toi avec :"
echo "     - Utilisateur : $USERNAME"
echo "     - Mot de passe : [celui que tu as configuré]"
echo "=========================================="
echo ""

confirm "Redémarrer maintenant ?" && reboot