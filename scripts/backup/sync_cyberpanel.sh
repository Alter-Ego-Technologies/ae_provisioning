#!/usr/bin/env bash
set -e
STAMP=$(date +%F_%H%M%S)
LOG_FILE="/mnt/Backups/logs/cyberpanel_sync_${STAMP}.log"

log()   { echo "[$(date +'%F %T')] [INFO] $*" | tee -a "$LOG_FILE"; }
err()   { echo "[$(date +'%F %T')] [ERROR] $*" | tee -a "$LOG_FILE" >&2; }

mountpoint -q /mnt/Backups || { err "/mnt/Backups not mounted"; exit 1; }
exec 9>/tmp/cyberpanel-backup.lock
flock -n 9 || exit 0

# Source config from /mnt/Backups/cyberpanel/cyberpanel.conf if present
CONF_PATH="/mnt/Backups/cyberpanel/cyberpanel.conf"
if [ -f "$CONF_PATH" ]; then
  log "Sourcing config from $CONF_PATH"
  source "$CONF_PATH"
else
  err "Config file $CONF_PATH not found!"
  exit 1
fi

log "Starting CyberPanel rsync backup: gabe@${CP_PRI}:/home -> /mnt/Backups/cyberpanel/home"
if rsync -aHAX --numeric-ids --delete \
	-e "ssh -p ${CP_SSH_PORT} -i /home/gabe/.ssh/id_ed25519 -o StrictHostKeyChecking=accept-new" \
	--rsync-path="sudo /usr/bin/rsync" \
	gabe@${CP_PRI}:/home/ /mnt/Backups/cyberpanel/home/ >> "$LOG_FILE" 2>&1; then
  log "CyberPanel rsync completed."
else
  err "CyberPanel rsync failed. See $LOG_FILE for details."
  /mnt/Backups/scripts/backup_notify.sh cyberpanel failure "$LOG_FILE" 2>/dev/null || true
  exit 2
fi

log "Dumping CyberPanel databases to /mnt/Backups/cyberpanel/db/cyberpanel_${STAMP}.sql.gz"
if ssh -p ${CP_SSH_PORT} gabe@${CP_PRI} "mysqldump --defaults-file=~/.my.cnf --all-databases --single-transaction" 2>> "$LOG_FILE" | gzip > /mnt/Backups/cyberpanel/db/cyberpanel_${STAMP}.sql.gz; then
  log "CyberPanel backup completed successfully."
  /mnt/Backups/scripts/backup_notify.sh cyberpanel success "$LOG_FILE" 2>/dev/null || true
else
  err "CyberPanel backup failed. See $LOG_FILE for details."
  /mnt/Backups/scripts/backup_notify.sh cyberpanel failure "$LOG_FILE" 2>/dev/null || true
  exit 2
fi