#!/usr/bin/env bash
set -euo pipefail

# ============================================
# VÉRIFICATIONS INITIALES
# ============================================

# Vérification UEFI
if [[ ! -d /sys/firmware/efi ]]; then
  echo "❌ ERREUR: Ce script nécessite un démarrage UEFI." >&2
  exit 1
fi

# Vérification root
if [[ "${EUID}" -ne 0 ]]; then
  echo "❌ ERREUR: Root requis !" >&2
  exit 1
fi

# Vérification Live CD Void
if [[ ! -f /etc/os-release ]] || ! grep -q "Void" /etc/os-release; then
  echo "❌ ERREUR: Live CD Void Linux requis !" >&2
  exit 1
fi

# Charger dm-crypt
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
# FONCTIONS UTILITAIRES
# ============================================

# Logging
log() {
  echo "[$(date +%T)] $*"
}

# Titre de section
print_title() {
  echo -e "\n===== $1 =====\n"
}

# Étape
print_step() {
  echo "→ $1"
}

# Confirmation
confirm() {
  local prompt="${1:-Confirmer ?}"
  read -p "${prompt} [O/n] " -n 1 -r
  echo
  [[ "$REPLY" =~ ^[OoYy]$ ]]
}

# Nettoyage
cleanup() {
  log "🔄 Nettoyage avant sortie..."
  umount -R /mnt 2>/dev/null || true
  cryptsetup close cryptroot 2>/dev/null || true
  log "✅ Nettoyage terminé"
}

# Gestion d'erreur avancée
on_error() {
  local rc=$1 line=$2 cmd=$3
  echo >&2
  echo "==========================================" >&2
  echo "  ❌ INSTALLATION ÉCHOUÉE" >&2
  echo "  Code: ${rc}" >&2
  echo "  Ligne: ${line}" >&2
  echo "  Commande: ${cmd}" >&2
  echo "==========================================" >&2
  cleanup
  exit 1
}

trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR
trap cleanup EXIT

# Détection du type de partition (nvme vs sata)
part() {
  local disk="$1" n="$2"
  if [[ "${disk}" =~ nvme|loop ]]; then
    echo "${disk}p${n}"
  else
    echo "${disk}${n}"
  fi
}

# ============================================
# 1. SÉLECTION DU DISQUE
# ============================================
print_title "SÉLECTION DU DISQUE"

echo "Disques disponibles :"
mapfile -t DISK_LIST < <(lsblk -dpno NAME,SIZE,MODEL | grep -E '^/dev/(sd|nvme|vd)')

for i in "${!DISK_LIST[@]}"; do
  disk_name=$(echo "${DISK_LIST[$i]}" | awk '{print $1}')
  disk_size=$(echo "${DISK_LIST[$i]}" | awk '{print $2}')
  disk_model=$(echo "${DISK_LIST[$i]}" | awk '{print $3}')
  printf "  [%d] %s (%s - %s)\n" "$((i+1))" "${disk_name}" "${disk_size}" "${disk_model:-Inconnu}"
done

echo
while true; do
  read -r -p "Sélectionnez le numéro du disque: " DISK_NUM
  if [[ "${DISK_NUM}" =~ ^[0-9]+$ ]] && (( DISK_NUM >= 1 && DISK_NUM <= ${#DISK_LIST[@]} )); then
    TARGET_DISK=$(echo "${DISK_LIST[$((DISK_NUM-1))]}" | awk '{print $1}')
    break
  fi
  echo "❌ Sélection invalide."
done

log "Disque sélectionné: ${TARGET_DISK}"

# Définir les partitions
PART_EFI=$(part "${TARGET_DISK}" 1)
PART_BOOT=$(part "${TARGET_DISK}" 2)
PART_LUKS=$(part "${TARGET_DISK}" 3)

echo "Partitions:"
echo "  EFI:  ${PART_EFI}"
echo "  Boot: ${PART_BOOT}"
echo "  LUKS: ${PART_LUKS}"

echo
echo "⚠️  TOUTES LES DONNÉES SERONT EFFACÉES !"
confirm "Continuer ?" || exit 0

# ============================================
# 2. TIMEZONE
# ============================================
print_title "TIMEZONE"
DEFAULT_TIMEZONE="America/Montreal"
read -p "Timezone [${DEFAULT_TIMEZONE}]: " TIMEZONE
TIMEZONE="${TIMEZONE:-$DEFAULT_TIMEZONE}"

timedatectl list-timezones 2>/dev/null | grep -q "^$TIMEZONE$" || {
  echo "⚠️  '${TIMEZONE}' introuvable. Utilisation de $DEFAULT_TIMEZONE"
  TIMEZONE="$DEFAULT_TIMEZONE"
}

# ============================================
# 3. CONFIGURATION SYSTÈME
# ============================================
print_title "CONFIGURATION"
read -p "Hostname [${DEFAULT_HOSTNAME}]: " HOSTNAME
HOSTNAME="${HOSTNAME:-$DEFAULT_HOSTNAME}"

read -p "Utilisateur [${DEFAULT_USER}]: " USERNAME
USERNAME="${USERNAME:-$DEFAULT_USER}"

# ============================================
# 4. MOTS DE PASSE
# ============================================
print_title "MOTS DE PASSE"

ask_password() {
  local varname="$1"
  local prompt="$2"
  local pw pw2
  while true; do
    read -r -s -p "${prompt}: " pw
    echo
    read -r -s -p "Confirmer: " pw2
    echo
    if [[ "${pw}" == "${pw2}" ]]; then
      if [[ -n "${pw}" ]] && [[ ${#pw} -ge 8 ]]; then
        printf -v "${varname}" '%s' "${pw}"
        return
      else
        echo "❌ Mot de passe trop court (minimum 8 caractères)"
      fi
    else
      echo "❌ Les mots de passe ne correspondent pas"
    fi
  done
}

read -p "Un seul mot de passe pour tout (root + LUKS + user) ? [O/n] " -n 1 -r
if [[ $REPLY =~ ^[OoYy]$ ]]; then
  echo
  ask_password LUKS_PASS "Mot de passe (root + LUKS + ${USERNAME})"
  ROOT_PASS="$LUKS_PASS"
  USER_PASS="$LUKS_PASS"
else
  echo
  ask_password ROOT_PASS "Mot de passe root"
  ask_password LUKS_PASS "Mot de passe LUKS"
  ask_password USER_PASS "Mot de passe ${USERNAME}"
fi

# ============================================
# 5. PARTITIONNEMENT
# ============================================
print_title "PARTITIONNEMENT"
echo "  - EFI (${EFI_SIZE}, FAT32)"
echo "  - Boot (${BOOT_SIZE}, ext2)"
echo "  - Racine (LUKS + BTRFS)"
confirm "Continuer ?" || exit 0

log "Partitionnement de ${TARGET_DISK}..."
wipefs -af "${TARGET_DISK}" 2>/dev/null || true

sfdisk --force "${TARGET_DISK}" << SFDISK_EOF
label: gpt
size=+${EFI_SIZE}, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name=EFI
size=+${BOOT_SIZE}, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name=Boot
size=+, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name=Root
SFDISK_EOF

blockdev --rereadpt "${TARGET_DISK}"
udevadm settle --timeout=10

# Vérification partitions
for part in "${PART_EFI}" "${PART_BOOT}" "${PART_LUKS}"; do
  [[ -b "${part}" ]] || { echo "❌ Partition ${part} introuvable !"; exit 1; }
done

log "Partitions créées avec succès"

# ============================================
# 6. CHIFFREMENT LUKS
# ============================================
print_title "CHIFFREMENT LUKS"

# Nettoyage si signature LUKS existante
if cryptsetup isLuks "${PART_LUKS}" 2>/dev/null; then
  confirm "Signature LUKS existante. EFFACER ? (TOUTES LES DONNÉES SERONT PERDUES) !" || exit 1
  yes YES | cryptsetup erase "${PART_LUKS}" || exit 1
  sleep 2
fi

log "Chiffrement de ${PART_LUKS}..."
printf '%s' "${LUKS_PASS}" | cryptsetup luksFormat \
  --type luks2 \
  --pbkdf argon2id \
  --label cryptroot \
  "${PART_LUKS}" -

LUKS_UUID=$(cryptsetup luksUUID "${PART_LUKS}")
log "LUKS UUID: ${LUKS_UUID}"

log "Ouverture du conteneur LUKS..."
printf '%s' "${LUKS_PASS}" | cryptsetup open "${PART_LUKS}" cryptroot -

# Attendre que /dev/mapper/cryptroot soit disponible
udevadm settle --timeout=10

print_step "LUKS configuré avec succès"

# ============================================
# 7. FORMATAGE
# ============================================
print_title "FORMATAGE"

log "Formatage EFI..."
mkfs.fat -F32 -n EFI "${PART_EFI}" || exit 1

log "Formatage Boot..."
mkfs.ext2 -L grub "${PART_BOOT}" || exit 1

log "Formatage BTRFS..."
mkfs.btrfs -L Void /dev/mapper/cryptroot || exit 1

# ============================================
# 8. MONTAGE
# ============================================
print_title "MONTAGE"

log "Montage de /dev/mapper/cryptroot..."
mount -o "${BTRFS_OPTS}" /dev/mapper/cryptroot /mnt || exit 1

log "Création des subvolumes BTRFS..."
btrfs subvolume create /mnt/@ || exit 1
btrfs subvolume create /mnt/@home || exit 1
btrfs subvolume create /mnt/@snapshots || exit 1

umount /mnt || true
mount -o "${BTRFS_OPTS},subvol=@" /dev/mapper/cryptroot /mnt || exit 1

log "Création de l'arborescence..."
mkdir -p /mnt/{home,.snapshots,var/cache,efi,boot} || exit 1
btrfs subvolume create /mnt/var/cache/xbps || exit 1
btrfs subvolume create /mnt/var/tmp || exit 1
btrfs subvolume create /mnt/srv || exit 1

log "Montage de EFI et Boot..."
mount -o rw,noatime "${PART_EFI}" /mnt/efi || exit 1
mount -o rw,noatime "${PART_BOOT}" /mnt/boot || exit 1

# ============================================
# 9. INSTALLATION
# ============================================
print_title "INSTALLATION"

mkdir -p /mnt/var/db/xbps/keys
cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/ 2>/dev/null || true

log "Installation du système de base..."
XBPS_ARCH="${ARCH}" xbps-install -S -R "${REPO}" -r /mnt \
  base-system linux-mainline btrfs-progs cryptsetup vim sudo || exit 1

# ============================================
# 10. CONFIGURATION (CHROOT)
# ============================================
print_title "CONFIGURATION (CHROOT)"

# Bind mounts
for dir in dev proc sys run; do
  mount --rbind "/${dir}" "/mnt/${dir}"
  mount --make-rslave "/mnt/${dir}"
done
cp /etc/resolv.conf /mnt/etc/ 2>/dev/null || true

# Créer le script de configuration pour le chroot
cat > /mnt/tmp/setup.sh << CHROOT_SETUP_EOF
#!/usr/bin/env bash
set -euo pipefail
trap 'echo "CHROOT ERROR at line $LINENO" >&2' ERR

# Valeurs par défaut
LOCALE="${LOCALE:-en_US.UTF-8}"
BTRFS_OPTS="${BTRFS_OPTS:-rw,noatime,compress=zstd,discard=async}"

log() { echo "[chroot $(date +%T)] $*"; }

log "Configuration du système..."

# Hostname
echo "${HOSTNAME}" > /etc/hostname

# Locale
sed -i "s|#${LOCALE}|${LOCALE}|" /etc/default/libc-locales
xbps-reconfigure -f glibc-locales 2>/dev/null || true

# Timezone
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime

# /etc/hosts
cat > /etc/hosts << HOSTSEOF
127.0.0.1        localhost
::1              localhost
127.0.1.1        ${HOSTNAME}.localdomain ${HOSTNAME}
HOSTSEOF

# Mots de passe
echo "root:${ROOT_PASS}" | chpasswd
echo "${USERNAME}:${USER_PASS}" | chpasswd

# User
groupadd -f wheel 2>/dev/null || true
useradd -m -G wheel,audio,video,optical -s /bin/bash "${USERNAME}" 2>/dev/null || true

# Sudo
echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers

# Fstab
EFI_UUID=$(blkid -s UUID -o value ${PART_EFI})
BOOT_UUID=$(blkid -s UUID -o value ${PART_BOOT})

cat > /etc/fstab << FSTABEOF
# <file system>     <dir>        <type>    <options>               <dump> <pass>
UUID=${BOOT_UUID}   /boot        ext2     defaults,noatime      0      2
UUID=${EFI_UUID}    /boot/efi    vfat     defaults,noatime      0      2
/dev/mapper/cryptroot /            btrfs    ${BTRFS_OPTS},subvol=@   0      0
/dev/mapper/cryptroot /home        btrfs    ${BTRFS_OPTS},subvol=@home 0      0
/dev/mapper/cryptroot /.snapshots  btrfs    ${BTRFS_OPTS},subvol=@snapshots 0      0
tmpfs /tmp tmpfs defaults,nosuid,nodev 0 0
FSTABEOF

# Crypttab - UTILISE L'UUID LUKS
log "LUKS_UUID: ${LUKS_UUID}"
echo "cryptroot UUID=${LUKS_UUID} none luks,discard" > /etc/crypttab

# Dracut configuration
mkdir -p /etc/dracut.conf.d
cat > /etc/dracut.conf.d/crypt.conf << DRACUTCONF
add_dracutmodules+=" crypt "
kernel_cmdline="rd.luks.uuid=${LUKS_UUID} rd.luks.name=${LUKS_UUID}=cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rootfstype=btrfs"
DRACUTCONF

log "Génération de l'initramfs..."
dracut --force --kver "$(ls -1 /lib/modules | sort -V | tail -1)" 2>/dev/null || true

# GRUB configuration
cat > /etc/default/grub << GRUBCFG
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="Void"
GRUB_CMDLINE_LINUX_DEFAULT="loglevel=4"
GRUB_CMDLINE_LINUX="rd.luks.uuid=${LUKS_UUID} rd.luks.name=${LUKS_UUID}=cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rootfstype=btrfs"
GRUB_ENABLE_CRYPTODISK=n
GRUBCFG

log "Installation de GRUB..."
grub-install \
  --target=x86_64-efi \
  --efi-directory=/boot/efi \
  --bootloader-id=Void \
  --recheck 2>/dev/null || exit 1

grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || true

# Réseau
ln -sf /etc/sv/dhcpcd /var/service/ 2>/dev/null || true
ln -sf /etc/sv/NetworkManager /var/service/ 2>/dev/null || true

# Repositories
xbps-install -S 2>/dev/null || true
xbps-install -y void-repo-nonfree 2>/dev/null || true
xbps-install -S 2>/dev/null || true
xbps-install -y void-repo-multilib 2>/dev/null || true
xbps-install -S 2>/dev/null || true

log "Reconfiguration finale..."
xbps-reconfigure -fa 2>/dev/null || true

log "Installation de git..."
xbps-install -y git 2>/dev/null || true

log "Chroot setup complete."
CHROOT_SETUP_EOF

chmod +x /mnt/tmp/setup.sh

# Copier resolv.conf pour le chroot
cp -L /etc/resolv.conf /mnt/etc/resolv.conf

log "Exécution de la configuration dans le chroot..."
chroot /mnt /tmp/setup.sh

# Nettoyer le script temporaire
rm -f /mnt/tmp/setup.sh

# ============================================
# 11. FINALISATION
# ============================================
print_title "FINALISATION"

log "Démontage..."
for dir in dev proc sys run; do
  umount -R "/mnt/${dir}" 2>/dev/null || true
done

umount -R /mnt 2>/dev/null || true
cryptsetup close cryptroot 2>/dev/null || true

echo
echo "=========================================="
echo "  ✅ INSTALLATION TERMINÉE !"
echo "=========================================="
echo "  Disque       : ${TARGET_DISK}"
echo "  LUKS UUID    : ${LUKS_UUID}"
echo "  Hostname     : ${HOSTNAME}"
echo "  Utilisateur  : ${USERNAME}"
echo "=========================================="
echo "  Redémarrez avec: reboot"
echo "=========================================="

if confirm "Redémarrer maintenant ?"; then
  reboot
fi
