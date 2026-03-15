#!/usr/bin/env bash
set -e
STAMP=$(date +%F_%H%M%S)
LOG_FILE="/mnt/Backups/logs/cloud_sync_${STAMP}.log"

log()   { echo "[$(date +'%F %T')] [INFO] $*" | tee -a "$LOG_FILE"; }
err()   { echo "[$(date +'%F %T')] [ERROR] $*" | tee -a "$LOG_FILE" >&2; }

BACKUP_ROOT="/mnt/Backups"
CONF_PATH="$BACKUP_ROOT/remote.conf"

if [ ! -f "$CONF_PATH" ]; then
  echo "[$(date +'%F %T')] [INFO] Cloud sync skipped: $CONF_PATH not found. Copy config/backup/remote.conf.example and configure."
  exit 0
fi

source "$CONF_PATH"

if [ -z "${RCLONE_REMOTE:-}" ] || [ "$RCLONE_REMOTE" = "remote:bucket/backups" ]; then
  echo "[$(date +'%F %T')] [INFO] Cloud sync skipped: RCLONE_REMOTE not configured in $CONF_PATH"
  exit 0
fi

# Optional: encrypt sensitive subdirs before upload (set RCLONE_REMOTE_CRYPT for encrypted copy)
REMOTE="${RCLONE_REMOTE}"
if [ -n "${RCLONE_REMOTE_CRYPT:-}" ]; then
  REMOTE="$RCLONE_REMOTE_CRYPT"
fi

log "Starting cloud sync: $BACKUP_ROOT -> $REMOTE"
exec 9>/tmp/cloud-backup.lock
flock -n 9 || { log "Another cloud sync already running, skipping"; exit 0; }

RCLONE_OPTS=(--transfers 4 --checkers 8 --log-file "$LOG_FILE" --log-level INFO)

# 1) Sync everything except .conf so mirror/delete never removes .conf on remote (e.g. mail/.conf from mount)
if ! rclone sync "$BACKUP_ROOT" "$REMOTE" \
  --exclude "logs/*.log" \
  --exclude "*.lock" \
  --exclude "*.conf" \
  --exclude "**/*.conf" \
  "${RCLONE_OPTS[@]}"; then
  err "Cloud sync failed. See $LOG_FILE for details."
  /mnt/Backups/scripts/backup_notify.sh cloud failure "$LOG_FILE" 2>/dev/null || true
  exit 2
fi

# 2) Copy .conf files only (add/update, never delete) so configs stay in backup
if ! rclone copy "$BACKUP_ROOT" "$REMOTE" \
  --include "*.conf" \
  --include "**/*.conf" \
  "${RCLONE_OPTS[@]}"; then
  err "Cloud sync: .conf copy failed. See $LOG_FILE for details."
  /mnt/Backups/scripts/backup_notify.sh cloud failure "$LOG_FILE" 2>/dev/null || true
  exit 2
fi

log "Cloud sync completed successfully."
/mnt/Backups/scripts/backup_notify.sh cloud success "$LOG_FILE" 2>/dev/null || true
