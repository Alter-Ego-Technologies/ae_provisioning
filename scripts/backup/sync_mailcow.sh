#!/usr/bin/env bash
set -e
mountpoint -q /mnt/Backups || { echo "ERROR: /mnt/Backups not mounted"; exit 1; }
exec 9>/var/lock/backup.lock
flock -n 9 || exit 0

MC_PRI=10.0.0.12
MC_BACKUP_SRC="/opt/mailcow-dockerized/backup"

# Source config from /mnt/Backups/mailcow/mailcow.conf if present
CONF_PATH="/mnt/Backups/mailcow/mailcow.conf"
[ -f "$CONF_PATH" ] && source "$CONF_PATH"

rsync -aHAX --delete -e ssh root@${MC_PRI}:${MC_BACKUP_SRC}/ /mnt/Backups/mailcow/backups/
