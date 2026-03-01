#!/usr/bin/env bash
set -e
STAMP=$(date +%F_%H%M%S)
LOG_FILE="/mnt/Backups/logs/standalone_sync_${STAMP}.log"

log()   { echo "[$(date +'%F %T')] [INFO] $*" | tee -a "$LOG_FILE"; }
err()   { echo "[$(date +'%F %T')] [ERROR] $*" | tee -a "$LOG_FILE" >&2; }

mountpoint -q /mnt/Backups || { err "/mnt/Backups not mounted"; exit 1; }
exec 9>/tmp/standalone-backup.lock
flock -n 9 || exit 0

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
mkdir -p "${STANDALONE_DATA_DST}"
chmod -R 777 "${STANDALONE_DATA_DST}"
chown -R "${STANDALONE_SSH_USER}:${STANDALONE_SSH_USER}" "${STANDALONE_DATA_DST}"

log "Starting standalone rsync backup: ${STANDALONE_SSH_USER}@${STANDALONE_PRI}:${STANDALONE_DATA_SRC} -> ${STANDALONE_DATA_DST}"
# Rsync standalone files (do not preserve group to avoid chgrp errors)
if rsync -aHAX --no-group --delete -e "ssh -p ${STANDALONE_SSH_PORT}" ${STANDALONE_SSH_USER}@${STANDALONE_PRI}:${STANDALONE_DATA_SRC}/ ${STANDALONE_DATA_DST}/ >> "$LOG_FILE" 2>&1; then
  log "Standalone files backup completed successfully."
else
  err "Standalone backup failed. See $LOG_FILE for details."
  exit 2
fi
