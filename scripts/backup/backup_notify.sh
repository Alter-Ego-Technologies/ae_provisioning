#!/usr/bin/env bash
# Send backup success/failure notification email.
# Usage: backup_notify.sh JOB_NAME status [LOG_FILE]
#   JOB_NAME: e.g. nextcloud, mailcow, cyberpanel, standalone, cloud
#   status:   success or failure
#   LOG_FILE: optional path to append last N lines to body

set -e

JOB="$1"
STATUS="${2:-success}"
LOG_FILE="${3:-}"

BACKUP_ROOT="/mnt/Backups"
CONF_PATH="$BACKUP_ROOT/notify.conf"

if [ -f "$CONF_PATH" ]; then
  # shellcheck source=/dev/null
  source "$CONF_PATH"
fi

TO_RAW="${BACKUP_NOTIFY_TO:-admins@alteregotech.com admins@clearpointreporting.com}"
# To: header requires comma-separated; convert spaces to ", "
TO_HEADER="${TO_RAW// /, }"
# From must match msmtprc / relay (e.g. server-alerts@alteregotech.com) or relay may reject
FROM="${BACKUP_NOTIFY_FROM:-server-alerts@alteregotech.com}"
HOST=$(hostname -f 2>/dev/null || hostname)
SUBJECT="[Backup ${STATUS}] $JOB - $HOST - $(date '+%Y-%m-%d %H:%M')"
NOTIFY_ERR_LOG="${BACKUP_ROOT}/logs/backup_notify.err"

BODY=$(mktemp)
{
  echo "Backup job: $JOB"
  echo "Status: $STATUS"
  echo "Host: $HOST"
  echo "Time: $(date -Iseconds)"
  echo ""
  if [ -n "$LOG_FILE" ] && [ -f "$LOG_FILE" ]; then
    echo "--- Last 20 lines of log ---"
    tail -20 "$LOG_FILE"
  fi
} > "$BODY"

if ! {
  echo "To: ${TO_HEADER}"
  echo "From: ${FROM}"
  echo "Subject: ${SUBJECT}"
  echo "Content-Type: text/plain; charset=UTF-8"
  echo ""
  cat "$BODY"
} | /usr/sbin/sendmail -t 2>>"${NOTIFY_ERR_LOG}"; then
  echo "[$(date -Iseconds)] backup_notify sendmail failed: $JOB $STATUS" >>"${NOTIFY_ERR_LOG}"
fi
rm -f "$BODY"
