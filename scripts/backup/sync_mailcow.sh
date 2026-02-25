#!/usr/bin/env bash
set -e
mountpoint -q /mnt/Backups || { echo "ERROR: /mnt/Backups not mounted"; exit 1; }
exec 9>/var/lock/backup.lock
flock -n 9 || exit 0

MC_PRI=10.0.0.12
MC_BACKUP_SRC="/opt/mailcow-dockerized/backup"

rsync -aHAX --delete -e ssh root@${MC_PRI}:${MC_BACKUP_SRC}/ /mnt/Backups/mailcow/backups/
