#!/bin/bash
set -euo pipefail

# ============================================
# Vérifications préliminaires
# ============================================
[ "\$EUID" -ne 0 ] && { echo "❌ Ce script doit être exécuté en root !"; exit 1; }
[ ! -f /etc/os-release ] && { echo "❌ Exécute depuis un live CD Void Linux !"; exit 1; }

# ============================================
# Configuration par défaut
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
# Fonctions utilitaires
# ============================================
print_title()  { echo -e "\n===== \$1 =====\n"; }
print_step()   { echo "→ \$1"; }
confirm()      {
  read -p "\$1 [O/n] " -n 1 -r
  echo
  [[ ! $REPLY =~ ^[OoYy]$ ]] && return 1 || return 0
}

# ============================================
# 1. Sélection du disque
# ============================================
print_title "SÉLECTION DU DISQUE"
echo "Disques disponibles :"
select DISK in \$(lsblk -d -n -o NAME | sort); do
  [ -n "\$DISK" ] && DISK="/dev/\$DISK" && break
done
echo "Disque sélectionné : \$DISK"
confirm "Confirmer ? TOUTES LES DONNÉES SERONT EFFACÉES !" || exit 1

# ============================================
# 2. Timezone (défaut : Montréal)
# ============================================
print_title "TIMEZONE"
DEFAULT_TIMEZONE="America/Montreal"
read -p "Timezone [$DEFAULT_TIMEZONE] : " TIMEZONE
TIMEZONE="${TIMEZONE:-\$DEFAULT_TIMEZONE}"
if ! timedatectl list-timezones 2>/dev/null | grep -q "^$TIMEZONE$"; then
  echo "⚠️  '\$TIMEZONE' introuvable. Utilisation de \$DEFAULT_TIMEZONE"
  TIMEZONE="\$DEFAULT_TIMEZONE"
fi
print_step "Timezone : \$TIMEZONE"

# ============================================
# 3. Configuration système
# ============================================
print_title "CONFIGURATION SYSTÈME"
read -p "Nom de la machine [$DEFAULT_HOSTNAME] : " HOSTNAME
HOSTNAME="${HOSTNAME:-\$DEFAULT_HOSTNAME}"
read -p "Nom d'utilisateur [$DEFAULT_USER] : " USERNAME
USERNAME="${USERNAME:-\$DEFAULT_USER}"
print_step "Hostname : \$HOSTNAME | Utilisateur : \$USERNAME"

# ============================================
# 4. Mots de passe (NOUVEAU : choix entre commun ou séparé)
# ============================================
print_title "MOTS DE PASSE"
read -p "Utiliser le MÊME mot de passe pour root, LUKS et utilisateur ? [O/n] " -n 1 -r
echo
if [[ $REPLY =~ ^[OoYy]$ ]]; then
  # ==> Un seul mot de passe pour tout
  while true; do
    read -sp "Mot de passe (root + LUKS + \$USERNAME) : " pwd1; echo
    read -sp "Conf