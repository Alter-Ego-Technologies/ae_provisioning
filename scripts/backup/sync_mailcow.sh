#!/usr/bin/env bash
set -e
mountpoint -q /mnt/Backups || { echo "ERROR: /mnt/Backups not mounted"; exit 1; }
exec 9>/tmp/mailcow-backup.lock
flock -n 9 || exit 0

# Source config from /mnt/Backups/mailcow/mailcow.conf if present
CONF_PATH="/mnt/Backups/mailcow/mailcow.conf"
[ -f "$CONF_PATH" ] && source "$CONF_PATH"

rsync -aHAX --no-group --delete -e "ssh -p ${MC_SSH_PORT}" ${MC_SSH_USER}@${MC_PRI}:${MC_BACKUP_SRC}/ ${MC_BACKUP_DST}/
