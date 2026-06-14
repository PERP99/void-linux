#!/bin/bash
set -eu

# ============================================
# VÉRIFICATIONS
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
wait_for_partitions() {
  local disk="$1"
  local max_attempts=10
  local attempt=1
  print_step "Attente de la détection des partitions..."
  while [ $attempt -le $max_attempts ]; do
    if lsblk "$disk" | grep -q "${disk}p3\$"; then
      print_step "Partitions détectées !"
      return 0
    fi
    print_step "Tentative $attempt/$max_attempts..."
    udevadm settle --timeout=5 2>/dev/null || sleep 2
    ((attempt++))
  done
  echo "❌ Partitions non détectées après $max_attempts tentatives"
  return 1
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
# 5. PARTITIONNEMENT (sfdisk + attente)
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

# Attendre que le noyau détecte les nouvelles partitions
wait_for_partitions "$DISK" || exit 1
partprobe "$DISK" 2>/dev/null || true
sleep 3

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

# Vérification que les partitions existent
[ ! -e "$EFI_PART" ] && { echo "❌ Partition EFI $EFI_PART introuvable !"; exit 1; }
[ ! -e "$BOOT_PART" ] && { echo "❌ Partition Boot $BOOT_PART introuvable !"; exit 1; }
[ ! -e "$ROOT_PART" ] && { echo "❌ Partition Racine $ROOT_PART introuvable !"; exit 1; }

print_step "Partitions créées : $EFI_PART, $BOOT_PART, $ROOT_PART"

# ============================================
# 6. CHIFFREMENT LUKS (avec vérification)
# ============================================
print_title "CHIFFREMENT LUKS"
print_step "Vérification que $ROOT_PART existe..."
[ ! -e "$ROOT_PART" ] && { echo "❌ $ROOT_PART n'existe pas !"; lsblk "$DISK"; exit 1; }

print_step "Chiffrement de $ROOT_PART (cela peut prendre du temps)..."
echo -e "$LUKS_PWD\\n$LUKS_PWD" | cryptsetup luksFormat --type luks1 -y "$ROOT_PART" - 2>&1 || {
  echo "❌ Échec du chiffrement LUKS !"
  echo "Vérifie que :"
  echo "  - Le disque $DISK est bien sélectionné"
  echo "  - La partition $ROOT_PART existe (lsblk)"
  echo "  - cryptsetup est installé (xbps-install -y cryptsetup)"
  exit 1
}

print_step "Ouverture du conteneur LUKS..."
echo "$LUKS_PWD" | cryptsetup open "$ROOT_PART" cryptroot - 2>&1 || {
  echo "❌ Échec de l'ouverture LUKS !"
  echo "Mot de passe incorrect ou partition corrompue."
  exit 1
}

# Vérification que /dev/mapper/cryptroot existe
[ ! -e "/dev/mapper/cryptroot" ] && {
  echo "❌ /dev/mapper/cryptroot introuvable !"
  ls /dev/mapper/
  exit 1
}

print_step "Formatage des partitions..."
mkfs.fat -F32 -n EFI "$EFI_PART" 2>&1 || { echo "❌ Échec formatage EFI !"; exit 1; }
mkfs.ext2 -L grub "$BOOT_PART" 2>&1 || { echo "❌ Échec formatage Boot !"; exit 1; }
mkfs.btrfs -L Void /dev/mapper/cryptroot 2>&1 || { echo "❌ Échec formatage BTRFS !"; exit 1; }

# ============================================
# 7. MONTAGE (avec vérifications)
# ============================================
print_title "MONTAGE"

print_step "Montage de la partition racine..."
mount -o "$BTRFS_OPTS" /dev/mapper/cryptroot /mnt 2>&1 || {
  echo "❌ Échec montage racine !"
  echo "Vérifie que /mnt existe et que BTRFS est supporté."
  exit 1
}

print_step "Création des subvolumes BTRFS..."
btrfs subvolume create /mnt/@ 2>&1 || { echo "❌ Échec création @ !"; exit 1; }
btrfs subvolume create /mnt/@home 2>&1 || { echo "❌ Échec création @home !"; exit 1; }
btrfs subvolume create /mnt/@snapshots 2>&1 || { echo "❌ Échec création @snapshots !"; exit 1; }

print_step "Démontage et remontage avec subvolume @..."
umount /mnt 2>/dev/null || true
mount -o "$BTRFS_OPTS,subvol=@" /dev/mapper/cryptroot /mnt 2>&1 || {
  echo "❌ Échec remontage avec subvolume @ !"; exit 1
}

print_step "Création des répertoires..."
mkdir -p /mnt/{home,.snapshots,var/cache,efi,boot} 2>&1 || { echo "❌ Échec création répertoires !"; exit 1; }

print_step "Création des subvolumes supplémentaires..."
btrfs subvolume create /mnt/var/cache/xbps 2>&1 || { echo "❌ Échec création var/cache/xbps !"; exit 1; }
btrfs subvolume create /mnt/var/tmp 2>&1 || { echo "❌ Échec création var/tmp !"; exit 1; }
btrfs subvolume create /mnt/srv 2>&1 || { echo "❌ Échec création srv !"; exit 1; }

print_step "Montage des partitions EFI et Boot..."
mount -o rw,noatime "$EFI_PART" /mnt/efi 2>&1 || { echo "❌ Échec montage EFI !"; exit 1; }
mount -o rw,noatime "$BOOT_PART" /mnt/boot 2>&1 || { echo "❌ Échec montage Boot !"; exit 1; }

print_step "Vérification des points de montage :"
df -h | grep /mnt

# ============================================
# 8. INSTALLATION
# ============================================
print_title "INSTALLATION DU SYSTÈME DE BASE"

print_step "Copie des clés XBPS..."
mkdir -p /mnt/var/db/xbps/keys
cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/ 2>/dev/null || echo "⚠️ Aucune clé XBPS trouvée"

print_step "Installation des paquets de base..."
XBPS_ARCH="$ARCH" xbps-install -S -R "$REPO" -r /mnt base-system linux-mainline btrfs-progs cryptsetup vim sudo 2>&1 || {
  echo "❌ Échec installation des paquets de base !"
  echo "Vérifie ta connexion internet et le miroir : $REPO"
  exit 1
}

# ============================================
# 9. CHROOT
# ============================================
print_title "CONFIGURATION (CHROOT)"

print_step "Préparation de l'environnement chroot..."
for dir in dev proc sys run; do
  mount --rbind /$dir /mnt/$dir 2>/dev/null || { echo "❌ Échec mount --rbind /$dir !"; exit 1; }
  mount --make-rslave /mnt/$dir 2>/dev/null || { echo "❌ Échec mount --make-rslave !"; exit 1; }
done
cp /etc/resolv.conf /mnt/etc/ 2>/dev/null || echo "⚠️ /etc/resolv.conf introuvable"

# Export des variables pour le chroot
export TIMEZONE HOSTNAME USERNAME LOCALE ROOT_PWD USER_PWD LUKS_PWD EFI_PART BOOT_PART BTRFS_OPTS

print_step "Exécution des commandes dans le chroot..."
chroot /mnt /bin/bash <<'CHROOT_EOF'
# Timezone et Locale
ln -sf /usr/share/zoneinfo/"$TIMEZONE" /etc/localtime
sed -i "s|#$LOCALE|$LOCALE|" /etc/default/libc-locales
xbps-reconfigure -f glibc-locales 2>/dev/null || echo "⚠️ Erreur configuration locale"

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
xbps-install -y void-repo-nonfree 2>/dev/null || echo "⚠️ void-repo-nonfree introuvable"
xbps-install -S
xbps-install -y void-repo-multilib 2>/dev/null || echo "⚠️ void-repo-multilib introuvable"
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
xbps-install -y grub-x86_64-efi 2>/dev/null || echo "⚠️ grub-x86_64-efi introuvable"
grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id="Void" 2>/dev/null || {
  echo "❌ Échec installation GRUB !"
  exit 1
}

# Services
echo "hostonly=yes" >> /etc/dracut.conf
ln -s /etc/sv/dhcpcd /var/service/ 2>/dev/null || echo "⚠️ dhcpcd introuvable"
ln -s /etc/sv/NetworkManager /var/service/ 2>/dev/null || echo "⚠️ NetworkManager introuvable"
xbps-reconfigure -fa 2>/dev/null || echo "⚠️ Erreur reconfiguration"
xbps-install -y git NetworkManager 2>/dev/null || echo "⚠️ git/NetworkManager introuvable"
CHROOT_EOF

# ============================================
# 10. FINALISATION
# ============================================
print_title "FINALISATION"
print_step "Démontage des partitions..."
umount -R /mnt 2>/dev/null || echo "⚠️ Avertissement lors du démontage"

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