#!/usr/bin/env bash
set -e
mountpoint -q /mnt/Backups || { echo "ERROR: /mnt/Backups not mounted"; exit 1; }
exec 9>/tmp/mailcow-backup.lock
flock -n 9 || exit 0

STAMP=$(date +%F_%H%M%S)
LOG_FILE="/mnt/Backups/logs/mailcow_sync_${STAMP}.log"

log()   { echo "[$(date +'%F %T')] [INFO] $*" | tee -a "$LOG_FILE"; }
err()   { echo "[$(date +'%F %T')] [ERROR] $*" | tee -a "$LOG_FILE" >&2; }

mountpoint -q /mnt/Backups || { err "/mnt/Backups not mounted"; exit 1; }
exec 9>/tmp/mailcow-backup.lock
flock -n 9 || exit 0

CONF_PATH="/mnt/Backups/mailcow/mailcow.conf"
if [ -f "$CONF_PATH" ]; then
	log "Sourcing config from $CONF_PATH"
	source "$CONF_PATH"
else
	err "Config file $CONF_PATH not found!"
	exit 1
fi

log "Starting mailcow rsync backup: ${MC_SSH_USER}@${MC_PRI}:${MC_BACKUP_SRC} -> ${MC_BACKUP_DST}"
if rsync -aHAX --numeric-ids --no-group --delete --exclude="mailcow.conf" \
	-e "ssh -p ${MC_SSH_PORT} -i /home/gabe/.ssh/id_ed25519" \
	--rsync-path="sudo /usr/bin/rsync" \
	${MC_SSH_USER}@${MC_PRI}:${MC_BACKUP_SRC}/ ${MC_BACKUP_DST}/ >> "$LOG_FILE" 2>&1; then
	log "Mailcow rsync backup completed successfully."
else
	err "Mailcow rsync backup failed. See $LOG_FILE for details."
	exit 2
fi


# Ensure mail sync is stored in /mnt/Backups/mailcow
# Remove duplicate/legacy rsync and clarify log messages
