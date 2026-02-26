#!/usr/bin/env bash
set -e
mountpoint -q /mnt/Backups || { echo "ERROR: /mnt/Backups not mounted"; exit 1; }
exec 9>/tmp/webstack-backup.lock
flock -n 9 || exit 0

STAMP=$(date +%F_%H%M%S)

# Source config from /mnt/Backups/webstack/webstack.conf if present
CONF_PATH="/mnt/Backups/webstack/webstack.conf"
[ -f "$CONF_PATH" ] && source "$CONF_PATH"

# Ensure destination exists
mkdir -p "$WEBSTACK_DATA_DST"

# Rsync webstack files
rsync -aHAX --delete -e "ssh -p ${WEBSTACK_SSH_PORT}" ${WEBSTACK_SSH_USER}@${WEBSTACK_PRI}:${WEBSTACK_DATA_SRC}/ ${WEBSTACK_DATA_DST}/

echo "[INFO] WebStack files backup complete: $STAMP"
