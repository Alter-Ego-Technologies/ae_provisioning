#!/usr/bin/env bash
set -e
BACKUP_ROOT="/mnt/Backups"
STAMP=$(date +%F_%H%M%S)
LOG_FILE="$BACKUP_ROOT/logs/nextcloud_sync_${STAMP}.log"

log()   { echo "[$(date +'%F %T')] [INFO] $*" | tee -a "$LOG_FILE"; }
err()   { echo "[$(date +'%F %T')] [ERROR] $*" | tee -a "$LOG_FILE" >&2; }

mountpoint -q "$BACKUP_ROOT" || { err "/mnt/Backups not mounted"; exit 1; }
LOCK_FILE="$BACKUP_ROOT/.nextcloud-backup.lock"
exec 9>"$LOCK_FILE" || { err "Cannot create lock file $LOCK_FILE (run as backup user?)"; exit 1; }
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
  /mnt/Backups/scripts/backup_notify.sh nextcloud failure "$LOG_FILE" 2>/dev/null || true
  exit 2
fi

log "Dumping Nextcloud database to $SQL_OUT"
if ssh -p ${NC_SSH_PORT} ${NC_SSH_USER}@${NC_PRI} "docker exec nextcloud_db mysqldump --single-transaction -u${DB_USER} -p'${DB_PASS}' ${DB_NAME}" > ${SQL_OUT} 2>> "$LOG_FILE"; then
  log "Nextcloud backup completed successfully."
  /mnt/Backups/scripts/backup_notify.sh nextcloud success "$LOG_FILE" 2>/dev/null || true
else
  err "Nextcloud backup failed. See $LOG_FILE for details."
  /mnt/Backups/scripts/backup_notify.sh nextcloud failure "$LOG_FILE" 2>/dev/null || true
  exit 2
fi
