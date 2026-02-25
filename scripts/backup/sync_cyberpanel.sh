#!/usr/bin/env bash
set -e
mountpoint -q /mnt/Backups || { echo "ERROR: /mnt/Backups not mounted"; exit 1; }
exec 9>/var/lock/backup.lock
flock -n 9 || exit 0

CP_PRI=10.0.0.13

rsync -aHAX --delete -e ssh root@${CP_PRI}:/home/ /mnt/Backups/cyberpanel/home/
STAMP=$(date +%F_%H%M%S)
ssh root@${CP_PRI} "mysqldump --all-databases --single-transaction" | gzip > /mnt/Backups/cyberpanel/db/cyberpanel_${STAMP}.sql.gz
