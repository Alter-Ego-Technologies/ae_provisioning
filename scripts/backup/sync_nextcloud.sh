#!/usr/bin/env bash
set -e
mountpoint -q /mnt/Backups || { echo "ERROR: /mnt/Backups not mounted"; exit 1; }
exec 9>/var/lock/backup.lock
flock -n 9 || exit 0

NC_PRI=10.0.0.11
NC_DATA_SRC="/REAL/DATA/PATH"
DB_NAME="nextcloud"
DB_USER="nextcloud"
DB_PASS="CHANGE_ME"

STAMP=$(date +%F_%H%M%S)
SQL_OUT="/mnt/Backups/nextcloud/sql/nextcloud_${STAMP}.sql"

# Source config from /mnt/Backups/nextcloud/nextcloud.conf if present
CONF_PATH="/mnt/Backups/nextcloud/nextcloud.conf"
[ -f "$CONF_PATH" ] && source "$CONF_PATH"

rsync -aHAX --delete -e ssh root@${NC_PRI}:${NC_DATA_SRC}/ /mnt/Backups/nextcloud/data/
ssh root@${NC_PRI} "mysqldump --single-transaction -u${DB_USER} -p'${DB_PASS}' ${DB_NAME}" > ${SQL_OUT}
