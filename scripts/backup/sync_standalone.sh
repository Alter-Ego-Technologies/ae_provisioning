#!/usr/bin/env bash
set -e
STAMP=$(date +%F_%H%M%S)
LOG_FILE="/mnt/Backups/logs/standalone_sync_${STAMP}.log"
LOCK_FILE="/tmp/standalone-backup.lock"

log()   { echo "[$(date +'%F %T')] [INFO] $*" | tee -a "$LOG_FILE"; }
err()   { echo "[$(date +'%F %T')] [ERROR] $*" | tee -a "$LOG_FILE" >&2; }

# Ensure log directory exists (may fail early if not mounted)
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || { echo "[ERROR] Cannot create log directory. /mnt/Backups not mounted?" >&2; exit 1; }

mountpoint -q /mnt/Backups || { err "/mnt/Backups not mounted"; exit 1; }

# Acquire exclusive lock with automatic cleanup
exec 9>"$LOCK_FILE" || { err "Cannot create lock file $LOCK_FILE"; exit 1; }
if ! flock -n 9; then
  log "Another standalone backup is running, skipping"
  exit 0
fi

# Source config from /mnt/Backups/standalone/standalone.conf if present
CONF_PATH="/mnt/Backups/standalone/standalone.conf"
if [ -f "$CONF_PATH" ]; then
  log "Sourcing config from $CONF_PATH"
  source "$CONF_PATH"
else
  err "Config file $CONF_PATH not found!"
  exit 1
fi

# Ensure required variables are set
: "${STANDALONE_DATA_DST:?STANDALONE_DATA_DST is not set}"
: "${STANDALONE_SSH_USER:?STANDALONE_SSH_USER is not set}"

# Ensure destination exists
#mkdir -p "${STANDALONE_DATA_DST}"
#chmod -R 777 "${STANDALONE_DATA_DST}"
#chown -R "${STANDALONE_SSH_USER}:${STANDALONE_SSH_USER}" "${STANDALONE_DATA_DST}"

log "Starting standalone rsync backup: ${STANDALONE_SSH_USER}@${STANDALONE_PRI}:${STANDALONE_DATA_SRC} -> ${STANDALONE_DATA_DST}"
# Rsync standalone files (do not preserve group to avoid chgrp errors)
# Exclude the config file itself to prevent it from being deleted by --delete
if rsync -aHAX --no-group --delete --exclude="standalone.conf" -e "ssh -p ${STANDALONE_SSH_PORT}" ${STANDALONE_SSH_USER}@${STANDALONE_PRI}:${STANDALONE_DATA_SRC}/ ${STANDALONE_DATA_DST}/ >> "$LOG_FILE" 2>&1; then
  log "Standalone files backup completed successfully."
else
  err "Standalone backup failed. See $LOG_FILE for details."
  exit 2
fi
