#!/usr/bin/env bash
set -e
BACKUP_ROOT="/mnt/Backups"
mountpoint -q "$BACKUP_ROOT" || { echo "ERROR: /mnt/Backups not mounted"; exit 1; }
LOCK_FILE="$BACKUP_ROOT/.mailcow-backup.lock"
exec 9>"$LOCK_FILE" || { echo "ERROR: Cannot create lock file $LOCK_FILE (run as backup user?)"; exit 1; }
flock -n 9 || exit 0

STAMP=$(date +%F_%H%M%S)
LOG_FILE="$BACKUP_ROOT/logs/mailcow_sync_${STAMP}.log"

log()   { echo "[$(date +'%F %T')] [INFO] $*" | tee -a "$LOG_FILE"; }
err()   { echo "[$(date +'%F %T')] [ERROR] $*" | tee -a "$LOG_FILE" >&2; }

CONF_PATH="/mnt/Backups/mailcow/mailcow.conf"
if [ -f "$CONF_PATH" ]; then
	log "Sourcing config from $CONF_PATH"
	source "$CONF_PATH"
else
	err "Config file $CONF_PATH not found!"
	exit 1
fi

# 1) Sync with --delete but exclude .conf so local .conf is never deleted (mount may not expose it)
log "Starting mailcow rsync backup: ${MC_SSH_USER}@${MC_PRI}:${MC_BACKUP_SRC} -> ${MC_BACKUP_DST}"
if ! rsync -aHAX --numeric-ids --no-group --delete --exclude="mailcow.conf" \
	-e "ssh -p ${MC_SSH_PORT} -i /home/gabe/.ssh/id_ed25519" \
	--rsync-path="sudo /usr/bin/rsync" \
	${MC_SSH_USER}@${MC_PRI}:${MC_BACKUP_SRC}/ ${MC_BACKUP_DST}/ >> "$LOG_FILE" 2>&1; then
	err "Mailcow rsync backup failed. See $LOG_FILE for details."
	exit 2
fi
# 2) Copy .conf from source when present (add/update, never delete)
rsync -aHAX --no-group -e "ssh -p ${MC_SSH_PORT} -i /home/gabe/.ssh/id_ed25519" \
	--rsync-path="sudo /usr/bin/rsync" \
	--include="mailcow.conf" --exclude="*" \
	${MC_SSH_USER}@${MC_PRI}:${MC_BACKUP_SRC}/ ${MC_BACKUP_DST}/ >> "$LOG_FILE" 2>&1 || true
log "Mailcow rsync backup completed successfully."


# Ensure mail sync is stored in /mnt/Backups/mailcow
# Remove duplicate/legacy rsync and clarify log messages
