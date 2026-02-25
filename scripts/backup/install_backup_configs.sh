#!/usr/bin/env bash
set -e

# Helper script to install example backup configs to the correct runtime locations
# Usage: Run from repo root as root or with sudo

REPO_CONFIG_DIR="$(dirname "$0")/../../config/backup"
BACKUPS_DIR="/mnt/Backups"

install_config() {
  local service="$1"
  local example="$REPO_CONFIG_DIR/${service}.conf.example"
  local dest="$BACKUPS_DIR/${service}/${service}.conf"
  mkdir -p "$BACKUPS_DIR/$service"
  if [ -f "$dest" ]; then
    echo "[SKIP] $dest already exists."
  else
    cp "$example" "$dest"
    echo "[OK] Installed $dest (edit with real values!)"
  fi
}

install_config nextcloud
install_config mailcow
install_config cyberpanel

echo "\nAll example configs installed. Edit them in /mnt/Backups/[service]/ before running backup scripts."
