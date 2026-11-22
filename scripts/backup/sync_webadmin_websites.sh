#!/usr/bin/env bash
set -euo pipefail

BACKUP_ROOT="/mnt/Backups"
DEST="$BACKUP_ROOT/cyberpanel/home"
LOG_DIR="$BACKUP_ROOT/logs"
STAMP=$(date +%F_%H%M%S)
LOG_FILE="$LOG_DIR/webadmin_websites_${STAMP}.log"

mountpoint -q "$BACKUP_ROOT" || {
  echo "ERROR: Backup volume not mounted"
  exit 1
}

mkdir -p "$LOG_DIR"

exec 9>"$BACKUP_ROOT/.webadmin-websites.lock"
flock -n 9 || {
  echo "Another website backup is running"
  exit 1
}

echo "Starting Webadmin website backup: $STAMP" | tee -a "$LOG_FILE"

rsync \
  -aHAX \
  --numeric-ids \
  --no-inplace \
  --no-whole-file \
  --stats \
  -e "ssh -p 2222 -i /home/gabe/.ssh/id_ed25519 -o BatchMode=yes -o StrictHostKeyChecking=yes" \
  --rsync-path="sudo -n /usr/bin/rsync" \
  gabe@10.0.1.2:/home/ \
  "$DEST/" >> "$LOG_FILE" 2>&1

# Record success only after rsync completes successfully.
touch /var/lib/ops-monitor/backup-success/webadmin_websites
echo "Webadmin website backup completed successfully" | tee -a "$LOG_FILE"
