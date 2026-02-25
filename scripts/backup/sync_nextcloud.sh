#!/usr/bin/env bash
set -e
mountpoint -q /mnt/Backups || { echo "ERROR: /mnt/Backups not mounted"; exit 1; }
exec 9>/tmp/backup.lock
flock -n 9 || exit 0

STAMP=$(date +%F_%H%M%S)
SQL_OUT="/mnt/Backups/nextcloud/sql/nextcloud_${STAMP}.sql"

# Source config from /mnt/Backups/nextcloud/nextcloud.conf if present
CONF_PATH="/mnt/Backups/nextcloud/nextcloud.conf"
[ -f "$CONF_PATH" ] && source "$CONF_PATH"

# Default SSH port and user if not set
NC_SSH_PORT="${NC_SSH_PORT:-22}"
NC_SSH_USER="${NC_SSH_USER:-root}"
NC_SERVER_NAME="${NC_SERVER_NAME:-nextcloud-primary}"

# Use /mnt/nextcloud as the backup source directory
NC_DATA_SRC="/mnt/nextcloud"

STAMP=$(date +%F_%H%M%S)
SQL_OUT="/mnt/Backups/nextcloud/sql/nextcloud_${STAMP}.sql"

echo "[INFO] Connecting to $NC_SERVER_NAME ($NC_PRI) as $NC_SSH_USER on port $NC_SSH_PORT"

rsync -aHAX --delete -e "ssh -p ${NC_SSH_PORT}" ${NC_SSH_USER}@${NC_PRI}:${NC_DATA_SRC}/ /mnt/Backups/nextcloud/data/
ssh -p ${NC_SSH_PORT} ${NC_SSH_USER}@${NC_PRI} "mysqldump --single-transaction -h${DB_HOST:-localhost} -P${DB_PORT:-3306} -u${DB_USER} -p'${DB_PASS}' ${DB_NAME}" > ${SQL_OUT}
