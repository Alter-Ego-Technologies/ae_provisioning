#!/usr/bin/env bash
set -Eeuo pipefail

BACKUP_ROOT="/mnt/Backups"
DEST_DIR="$BACKUP_ROOT/cyberpanel/db"
STAMP=$(date +%Y-%m-%d_%H%M%S)
DEST="$DEST_DIR/webadmin_${STAMP}.sql.gz"
TMP="${DEST}.partial"
LOG="$BACKUP_ROOT/logs/webadmin-db-cron.log"

SSH_KEY="/home/gabe/.ssh/id_ed25519"
SSH_HOST="gabe@10.0.1.2"
SSH_PORT=2222

log() {
  echo "[$(date '+%F %T')] $*" | tee -a "$LOG"
}

cleanup() {
  rm -f "$TMP"
}
trap cleanup EXIT

mountpoint -q "$BACKUP_ROOT" || {
  echo "Backup volume not mounted" >&2
  exit 1
}

mkdir -p "$DEST_DIR"

exec 9>"$BACKUP_ROOT/.webadmin-db.lock"
flock -n 9 || exit 0

log "Starting Webadmin MariaDB backup"

if ssh -i "$SSH_KEY" \
  -p "$SSH_PORT" \
  -o BatchMode=yes \
  -o ConnectTimeout=15 \
  "$SSH_HOST" \
  'sudo -n mariadb-dump -u root --all-databases --single-transaction --quick --routines --events --triggers' \
  | gzip > "$TMP"; then

  gzip -t "$TMP"

  SIZE=$(stat -c %s "$TMP")

  if (( SIZE < 1024 )); then
    log "ERROR: Database backup unexpectedly small: $SIZE bytes"
    exit 1
  fi

  mv "$TMP" "$DEST"
  sha256sum "$DEST" > "${DEST}.sha256"

  # Record success only after backup validation and checksum creation.
  touch /var/lib/ops-monitor/backup-success/webadmin_database
  log "SUCCESS: $DEST ($SIZE bytes)"
else
  log "ERROR: MariaDB backup failed"
  exit 1
fi
