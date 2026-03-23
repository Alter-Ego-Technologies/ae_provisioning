#!/bin/bash
set -euo pipefail

# Merge a Mail.bak tree into live Mail storage without deleting live data.
# Default source/target match this project's Mailcow layout.
SRC="${1:-/mnt/Mail.bak}"
DST="${2:-/mnt/Mail}"
LOG="${3:-/var/log/merge_mail_bak.log}"

if [[ ! -d "$SRC" ]]; then
  echo "ERROR: source '$SRC' not found"
  exit 1
fi
if [[ ! -d "$DST" ]]; then
  echo "ERROR: target '$DST' not found"
  exit 1
fi

echo "[$(date -Iseconds)] merge start src=$SRC dst=$DST" | tee -a "$LOG"

# Preview first. No delete, archive mode preserves ownership/perms/times.
echo "== DRY RUN ==" | tee -a "$LOG"
rsync -aHAXvn --numeric-ids "$SRC"/ "$DST"/ | tee -a "$LOG"

echo
read -r -p "Proceed with merge? (yes/no): " ans
if [[ "$ans" != "yes" ]]; then
  echo "Cancelled."
  exit 0
fi

# Real run. Still no --delete to avoid data loss.
rsync -aHAXv --numeric-ids "$SRC"/ "$DST"/ | tee -a "$LOG"

# Mailcow vmail permissions are usually uid/gid 5000.
chown -R 5000:5000 "$DST"

echo "[$(date -Iseconds)] merge complete" | tee -a "$LOG"
echo "Log: $LOG"
