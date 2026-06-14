#!/bin/bash
set -eu

# ============================================
# VÉRIFICATIONS INITIALES
# ============================================
[ "$EUID" -ne 0 ] && { echo "❌ Ce script doit être exécuté en root !"; exit 1; }
[ ! -f /etc/os-release ] && { echo "❌ Exécute depuis un live CD Void Linux !"; exit 1; }

# Charger les modules noyau nécessaires
modprobe dm-crypt 2>/dev/null || true

# ============================================
# CONFIGURATION PAR DÉFAUT
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
# FONCTIONS UTILITAIRES
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
# 1. SÉLECTION DU DISQUE
# ============================================
print_title "SÉLECTION DU DISQUE"
echo "Disques disponibles :"
DISK=""
select opt in $(lsblk -d -n -o NAME | sort); do
  [ -n "$opt" ] && DISK="/dev/$opt" && break
done
[ -z "$DISK" ] && { echo "❌ Aucun disque sélectionné !"; exit 1; }
echo "Disque sélectionné : $DISK"
confirm "Confirmer ? TOUTES LES DONNÉES SERONT EFFACÉES !" || exit 1

# ============================================
# 2. SÉLECTION DU TIMEZONE
# ============================================
print_title "SÉLECTION DU TIMEZONE"
DEFAULT_TIMEZONE="America/Montreal"
read -p "Timezone (laisser vide pour $DEFAULT_TIMEZONE) : " TIMEZONE
TIMEZONE="${TIMEZONE:-$DEFAULT_TIMEZONE}"
if ! timedatectl list-timezones 2>/dev/null | grep -q "^$TIMEZONE$"; then
  echo "⚠️  '$TIMEZONE' introuvable. Utilisation de $DEFAULT_TIMEZONE"
  TIMEZONE="$DEFAULT_TIMEZONE"
fi
print_step "Timezone sélectionné : $TIMEZONE"

# ============================================
# 3. CONFIGURATION SYSTÈME
# ============================================
print_title "CONFIGURATION SYSTÈME"
read -p "Nom de la machine (hostname) [$DEFAULT_HOSTNAME] : " HOSTNAME
HOSTNAME="${HOSTNAME:-$DEFAULT_HOSTNAME}"
read -p "Nom d'utilisateur [$DEFAULT_USER] : " USERNAME
USERNAME="${USERNAME:-$DEFAULT_USER}"
print_step "Configuration : Hostname=$HOSTNAME, Utilisateur=$USERNAME, Timezone=$TIMEZONE"

# ============================================
# 4. MOTS DE PASSE
# ============================================
print_title "CONFIGURATION DES MOTS DE PASSE"
read -p "Utiliser le MÊME mot de passe pour root, LUKS et utilisateur ? [O/n] " -n 1 -r
echo
if [[ $REPLY =~ ^[OoYy]$ ]]; then
  while true; do
    read -sp "Mot de passe (root + LUKS + $USERNAME) : " pwd1
    echo
    read -sp "Confirmer : " pwd2
    echo
    if [ "$pwd1" = "$pwd2" ] && [ -n "$pwd1" ]; then
      ROOT_PWD="$pwd1"
      LUKS_PWD="$pwd1"
      USER_PWD="$pwd1"
      break
    else
      echo "❌ Les mots de passe ne correspondent pas ou sont vides."
    fi
  done
else
  # Mot de passe root
  while true; do
    read -sp "Mot de passe root : " pwd1
    echo
    read -sp "Confirmer : " pwd2
    echo
    if [ "$pwd1" = "$pwd2" ] && [ -n "$pwd1" ]; then
      ROOT_PWD="$pwd1"
      break
    else
      echo "❌ Erreur"
    fi
  done

  # Mot de passe LUKS
  while true; do
    read -sp "Mot de passe LUKS (pour déchiffrer le disque) : " pwd1
    echo
    read -sp "Confirmer : " pwd2
    echo
    if [ "$pwd1" = "$pwd2" ] && [ -n "$pwd1" ]; then
      LUKS_PWD="$pwd1"
      break
    else
      echo "❌ Erreur"
    fi
  done

  # Mot de passe utilisateur
  while true; do
    read -sp "Mot de passe pour $USERNAME : " pwd1
    echo
    read -sp "Confirmer : " pwd2
    echo
    if [ "$pwd1" = "$pwd2" ] && [ -n "$pwd1" ]; then
      USER_PWD="$pwd1"
      break
    else
      echo "❌ Erreur"
    fi
  done
fi
print_step "Mots de passe configurés."

# ============================================
# 5. PARTITIONNEMENT (3 partitions : EFI + Boot + Racine)
# ============================================
print_title "PARTITIONNEMENT DU DISQUE"
echo "Configuration proposée :"
echo "  - Partition 1 : EFI ($EFI_SIZE, FAT32)"
echo "  - Partition 2 : Boot ($BOOT_SIZE, ext2)"
echo "  - Partition 3 : Racine (reste, LUKS + BTRFS)"
confirm "Continuer avec ce partitionnement ?" || exit 1

print_step "Création des partitions avec sfdisk..."
sfdisk --force "$DISK" <<EOF
label: gpt
start=2048, size=+$EFI_SIZE, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name=EFI
size=+$BOOT_SIZE, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name=Boot
type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name=Root
EOF

# Synchronisation avec le noyau
print_step "Synchronisation des partitions avec le noyau..."
partprobe "$DISK" 2>/dev/null || true
udevadm settle --timeout=5 2>/dev/null || sleep 3

# Détection du format de partition (nvme vs sda)
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

# Vérification ULTRA-ROBUSTE : on vérifie que les fichiers device EXISTENT
[ ! -b "$EFI_PART" ] && { echo "❌ $EFI_PART introuvable ! Vérifie avec : ls -l $EFI_PART"; exit 1; }
[ ! -b "$BOOT_PART" ] && { echo "❌ $BOOT_PART introuvable ! Vérifie avec : ls -l $BOOT_PART"; exit 1; }
[ ! -b "$ROOT_PART" ] && { echo "❌ $ROOT_PART introuvable ! Vérifie avec : ls -l $ROOT_PART"; exit 1; }

print_step "Partitions détectées :"
print_step "  EFI : $EFI_PART"
print_step "  Boot : $BOOT_PART"
print_step "  Racine : $ROOT_PART"

# ============================================
# 6. CHIFFREMENT LUKS (VERSION FINALE CORRIGÉE)
# ============================================
print_title "CHIFFREMENT LUKS"

# Vérifier si la partition a déjà une signature LUKS
if cryptsetup isLuks "$ROOT_PART" 2>/dev/null; then
  print_step "⚠️  $ROOT_PART contient DÉJÀ une signature LUKS !"
  print_step "Cela vient probablement d'une tentative précédente."
  confirm "EFFACER la signature existante ? (TOUTES LES DONNÉES SERONT PERDUES) !" || exit 1
  print_step "Nettoyage de la signature LUKS existante..."
  yes YES | cryptsetup erase "$ROOT_PART" || {
    echo "❌ Échec du nettoyage LUKS !"
    echo "Essaie manuellement : yes YES | cryptsetup erase $ROOT_PART"
    exit 1
  }
  sleep 2
fi

print_step "Vérification finale que $ROOT_PART existe et est accessible..."
[ ! -b "$ROOT_PART" ] && { echo "❌ $ROOT_PART n'existe pas !"; exit 1; }

print_step "Chiffrement de $ROOT_PART (cela peut prendre du temps)..."
# CORRECTION : printf au lieu de echo pour éviter les problèmes de saut de ligne
printf '%s\n%s\n' "$LUKS_PWD" "$LUKS_PWD" | cryptsetup luksFormat --type luks1 "$ROOT_PART" - || {
  echo "❌ Échec du chiffrement LUKS !"
  echo "Solutions :"
  echo "  1. Vérifie que cryptsetup est installé : xbps-install -y cryptsetup"
  echo "  2. Essaie manuellement : printf '%s\\n%s\\n' \"$LUKS_PWD\" \"$LUKS_PWD\" | cryptsetup luksFormat $ROOT_PART -"
  exit 1
}

print_step "Ouverture du conteneur LUKS..."
# CORRECTION : printf sans saut de ligne pour cryptsetup open
printf '%s' "$LUKS_PWD" | cryptsetup open "$ROOT_PART" cryptroot - || {
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
# 7. MONTAGE DES PARTITIONS
# ============================================
print_title "MONTAGE DES PARTITIONS"

print_step "Montage de la partition racine (BTRFS)..."
mount -o "$BTRFS_OPTS" /dev/mapper/cryptroot /mnt || { echo "❌ Échec montage racine !"; exit 1; }

print_step "Création des subvolumes BTRFS..."
btrfs subvolume create /mnt/@ || { echo "❌ Échec création @ !"; exit 1; }
btrfs subvolume create /mnt/@home || { echo "❌ Échec création @home !"; exit 1; }
btrfs subvolume create /mnt/@snapshots || { echo "❌ Échec création @snapshots !"; exit 1; }

print_step "Démontage et remontage avec subvolume @..."
umount /mnt || true
mount -o "$BTRFS_OPTS,subvol=@" /dev/mapper/cryptroot /mnt || { echo "❌ Échec remontage !"; exit 1; }

print_step "Création des répertoires et subvolumes supplémentaires..."
mkdir -p /mnt/{home,.snapshots,var/cache,efi,boot} || { echo "❌ Échec création répertoires !"; exit 1; }
btrfs subvolume create /mnt/var/cache/xbps || { echo "❌ Échec var/cache/xbps !"; exit 1; }
btrfs subvolume create /mnt/var/tmp || { echo "❌ Échec var/tmp !"; exit 1; }
btrfs subvolume create /mnt/srv || { echo "❌ Échec srv !"; exit 1; }

print_step "Montage des partitions EFI et Boot..."
mount -o rw,noatime "$EFI_PART" /mnt/efi || { echo "❌ Échec montage EFI !"; exit 1; }
mount -o rw,noatime "$BOOT_PART" /mnt/boot || { echo "❌ Échec montage Boot !"; exit 1; }

print_step "Vérification des points de montage :"
df -h | grep /mnt

# ============================================
# 8. INSTALLATION DU SYSTÈME DE BASE
# ============================================
print_title "INSTALLATION DU SYSTÈME DE BASE"

print_step "Copie des clés XBPS..."
mkdir -p /mnt/var/db/xbps/keys
cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/ 2>/dev/null || echo "⚠️ Aucune clé XBPS trouvée"

print_step "Installation des paquets de base..."
XBPS_ARCH="$ARCH" xbps-install -S -R "$REPO" -r /mnt base-system linux-mainline btrfs-progs cryptsetup vim sudo || {
  echo "❌ Échec installation des paquets !"
  echo "Vérifie ta connexion internet et le miroir : $REPO"
  exit 1
}

# ============================================
# 9. CONFIGURATION DANS LE CHROOT
# ============================================
print_title "CONFIGURATION (CHROOT)"

print_step "Préparation de l'environnement chroot..."
for dir in dev proc sys run; do
  mount --rbind /$dir /mnt/$dir || { echo "❌ Échec mount --rbind /$dir !"; exit 1; }
  mount --make-rslave /mnt/$dir || { echo "❌ Échec mount --make-rslave !"; exit 1; }
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

# Utilisateurs et mots de passe
echo "root:$ROOT_PWD" | chpasswd
useradd -m -G wheel -s /bin/bash "$USERNAME"
echo "$USERNAME:$USER_PWD" | chpasswd

# Configuration sudo
echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers

# Dépôts non-free et multilib
xbps-install -S
xbps-install -y void-repo-nonfree 2>/dev/null || echo "⚠️ void-repo-nonfree introuvable"
xbps-install -S
xbps-install -y void-repo-multilib 2>/dev/null || echo "⚠️ void-repo-multilib introuvable"
xbps-install -S

# intel-ucode (si disponible)
xbps-install -Su intel-ucode 2>/dev/null || echo "⚠️ intel-ucode introuvable"

# Configuration fstab
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

# Configuration GRUB pour LUKS
echo "GRUB_ENABLE_CRYPTODISK=y" >> /etc/default/grub
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=""/GRUB_CMDLINE_LINUX_DEFAULT="loglevel=4 rd.auto=1 rd.luks.allow-discards"/' /etc/default/grub

# Installation de GRUB
xbps-install -y grub-x86_64-efi 2>/dev/null || echo "⚠️ grub-x86_64-efi introuvable"
grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id="Void" 2>/dev/null || {
  echo "❌ Échec installation GRUB !"
  exit 1
}

# Configuration dracut
echo "hostonly=yes" >> /etc/dracut.conf

# Activation des services réseau
ln -s /etc/sv/dhcpcd /var/service/ 2>/dev/null || echo "⚠️ dhcpcd introuvable"
ln -s /etc/sv/NetworkManager /var/service/ 2>/dev/null || echo "⚠️ NetworkManager introuvable"

# Reconfiguration des paquets
xbps-reconfigure -fa 2>/dev/null || echo "⚠️ Erreur reconfiguration"

# Installation de paquets utiles
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