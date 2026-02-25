#!/usr/bin/env bash
set -e
mountpoint -q /mnt/Backups || { echo "ERROR: /mnt/Backups not mounted"; exit 1; }
exec 9>/tmp/web-backup.lock
flock -n 9 || exit 0

STAMP=$(date +%F_%H%M%S)

# Source config from /mnt/Backups/web/web.conf if present
CONF_PATH="/mnt/Backups/web/web.conf"
[ -f "$CONF_PATH" ] && source "$CONF_PATH"

# Ensure destination exists
mkdir -p "$WEB_DATA_DST"

# Rsync web files
rsync -aHAX --delete -e "ssh -p ${WEB_SSH_PORT}" ${WEB_SSH_USER}@${WEB_PRI}:${WEB_DATA_SRC}/ ${WEB_DATA_DST}/

echo "[INFO] Web files backup complete: $STAMP"
