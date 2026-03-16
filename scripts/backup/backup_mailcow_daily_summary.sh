#!/usr/bin/env bash
# Send one daily summary of Mailcow backup runs (last 24h).
# Run once per day via cron (e.g. 6:00) to avoid hourly emails.

set -e

BACKUP_ROOT="/mnt/Backups"
CONF_PATH="$BACKUP_ROOT/notify.conf"
LOG_DIR="${BACKUP_ROOT}/logs"

[ -d "$LOG_DIR" ] || exit 0

if [ -f "$CONF_PATH" ]; then
  # shellcheck source=/dev/null
  source "$CONF_PATH"
fi

TO_RAW="${BACKUP_NOTIFY_TO:-admins@alteregotech.com admins@clearpointreporting.com}"
# To: header requires comma-separated; convert spaces to ", "
TO_HEADER="${TO_RAW// /, }"
FROM="${BACKUP_NOTIFY_FROM:-server-alerts@alteregotech.com}"
HOST=$(hostname -f 2>/dev/null || hostname)
NOTIFY_ERR_LOG="${LOG_DIR}/backup_notify.err"

# Mailcow logs from last 24h
SUCCESS=0
FAIL=0
FAIL_LOGS=()

while IFS= read -r -d '' f; do
  if grep -q "completed successfully" "$f" 2>/dev/null; then
    ((SUCCESS++)) || true
  else
    ((FAIL++)) || true
    FAIL_LOGS+=("$f")
  fi
done < <(find "$LOG_DIR" -maxdepth 1 -name "mailcow_sync_*.log" -mmin -1440 -print0 2>/dev/null)

TOTAL=$((SUCCESS + FAIL))
if [ "$TOTAL" -eq 0 ]; then
  # No runs in last 24h - optional: send "no runs" or skip
  exit 0
fi

STATUS="OK"
[ "$FAIL" -gt 0 ] && STATUS="WARNING"

SUBJECT="[Mailcow Backup Daily Summary] $STATUS - $HOST - $(date '+%Y-%m-%d')"

BODY=$(mktemp)
{
  echo "Mailcow backup summary (last 24h)"
  echo "Host: $HOST"
  echo "Date: $(date -Iseconds)"
  echo ""
  echo "Successful runs: $SUCCESS"
  echo "Failed runs:     $FAIL"
  echo "Total runs:     $TOTAL"
  echo ""
  if [ "$FAIL" -gt 0 ] && [ ${#FAIL_LOGS[@]} -gt 0 ]; then
    echo "--- Failed run logs (last 15 lines each) ---"
    for f in "${FAIL_LOGS[@]}"; do
      echo ""
      echo ">>> $f <<<"
      tail -15 "$f" 2>/dev/null || true
    done
  fi
} > "$BODY"

# Timeout so cron doesn't hang if SMTP is unreachable
if ! {
  echo "To: ${TO_HEADER}"
  echo "From: ${FROM}"
  echo "Subject: ${SUBJECT}"
  echo "Content-Type: text/plain; charset=UTF-8"
  echo ""
  cat "$BODY"
} | timeout 30 /usr/sbin/sendmail -t 2>>"${NOTIFY_ERR_LOG}"; then
  echo "[$(date -Iseconds)] backup_mailcow_daily_summary sendmail failed (timeout or error)" >>"${NOTIFY_ERR_LOG}"
fi
rm -f "$BODY"
