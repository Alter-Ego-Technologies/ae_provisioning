#!/usr/bin/env bash
set -e
STAMP=$(date +%F_%H%M%S)
LOG_FILE="/mnt/Backups/logs/nextcloud_sync_${STAMP}.log"

log()   { echo "[$(date +'%F %T')] [INFO] $*" | tee -a "$LOG_FILE"; }
err()   { echo "[$(date +'%F %T')] [ERROR] $*" | tee -a "$LOG_FILE" >&2; }

mountpoint -q /mnt/Backups || { err "/mnt/Backups not mounted"; exit 1; }
exec 9>/tmp/nextcloud-backup.lock
flock -n 9 || exit 0

SQL_OUT="/mnt/Backups/nextcloud/sql/nextcloud_${STAMP}.sql"

# Source config from /mnt/Backups/nextcloud/nextcloud.conf if present
CONF_PATH="/mnt/Backups/nextcloud/nextcloud.conf"
if [ -f "$CONF_PATH" ]; then
  log "Sourcing config from $CONF_PATH"
  source "$CONF_PATH"
else
  err "Config file $CONF_PATH not found!"
  exit 1
fi

log "Starting Nextcloud backup: ${NC_SSH_USER}@${NC_PRI} (server: $NC_SERVER_NAME)"

if rsync -aHAX --delete -e "ssh -p ${NC_SSH_PORT}" ${NC_SSH_USER}@${NC_PRI}:${NC_DATA_SRC}/ /mnt/Backups/nextcloud/data/ >> "$LOG_FILE" 2>&1; then
  log "Nextcloud rsync completed."
else
  err "Nextcloud rsync failed. See $LOG_FILE for details."
  exit 2
fi

log "Dumping Nextcloud database to $SQL_OUT"
if ssh -p ${NC_SSH_PORT} ${NC_SSH_USER}@${NC_PRI} "docker exec nextcloud_db mysqldump --single-transaction -u${DB_USER} -p'${DB_PASS}' ${DB_NAME}" > ${SQL_OUT} 2>> "$LOG_FILE"; then
  log "Nextcloud backup completed successfully."
else
  err "Nextcloud backup failed. See $LOG_FILE for details."
  exit 2
fi
