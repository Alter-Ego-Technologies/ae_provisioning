#!/usr/bin/env bash
set -e
mountpoint -q /mnt/Backups || { echo "ERROR: /mnt/Backups not mounted"; exit 1; }
exec 9>/tmp/backup.lock
flock -n 9 || exit 0

# Source config from /mnt/Backups/cyberpanel/cyberpanel.conf if present
CONF_PATH="/mnt/Backups/cyberpanel/cyberpanel.conf"
[ -f "$CONF_PATH" ] && source "$CONF_PATH"

rsync -aHAX --delete -e ssh gabe@${CP_PRI}:/home/ /mnt/Backups/cyberpanel/home/
STAMP=$(date +%F_%H%M%S)
ssh gabe@${CP_PRI} "mysqldump --all-databases --single-transaction" | gzip > /mnt/Backups/cyberpanel/db/cyberpanel_${STAMP}.sql.gz