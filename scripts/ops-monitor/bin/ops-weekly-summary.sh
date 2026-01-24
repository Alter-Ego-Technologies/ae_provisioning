#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source /usr/local/sbin/ops-monitor-lib.sh

require_root
load_config

HOST="$(hostname_fqdn)"
NOW="$(date -Is)"
START="$(date -d '7 days ago' -Is 2>/dev/null || date -Is)"

section() {
  echo
  echo "==== $* ===="
}

# #legacy_health_check() {
#   section "Legacy server_health_check"
#   if command -v server_health_check >/dev/null 2>&1; then
#     server_health_check || true
#   else
#     echo "server_health_check not installed"
#   fi
# }

mail_section() {
  [[ "${ROLE:-base}" != "mail" ]] && return 0

  MAILCOW_ROOT="/opt/mailcow-dockerized"
  COMPOSE="/usr/bin/docker compose -f ${MAILCOW_ROOT}/docker-compose.yml"

  if [[ -d "$MAILCOW_ROOT" && -x /usr/bin/docker ]]; then
    section "Mail (Mailcow)"

    echo "-- Postfix queue (tail) --"
    ${COMPOSE} exec postfix-mailcow postqueue -p 2>/dev/null | tail -n 40 || true

    echo
    echo "-- Postfix warnings/errors (7d, tail) --"
    ${COMPOSE} logs --since "7d" --tail 250 postfix-mailcow 2>/dev/null | grep -Ei "warning|error|fatal|reject" || true

    echo
    echo "-- Dovecot warnings/errors (7d, tail) --"
    ${COMPOSE} logs --since "7d" --tail 250 dovecot-mailcow 2>/dev/null | grep -Ei "warning|error|fatal|auth" || true

    echo
    echo "-- Acme (last 50 lines) --"
    ${COMPOSE} logs --tail 50 acme-mailcow 2>/dev/null || true
  else
    section "Mail (Postfix/Dovecot)"
    if command -v postqueue >/dev/null 2>&1; then
      echo "-- Postfix queue (tail) --"
      postqueue -p 2>/dev/null | tail -n 40 || true
    else
      echo "postqueue not found"
    fi

    echo
    echo "-- Postfix warnings/errors (7d, tail) --"
    journalctl -u postfix --since "7 days ago" -p warning..alert --no-pager 2>/dev/null | tail -n 250 || true

    echo
    echo "-- Dovecot warnings/errors (7d, tail) --"
    journalctl -u dovecot --since "7 days ago" -p warning..alert --no-pager 2>/dev/null | tail -n 250 || true
  fi
}

body="$(
{
  echo "WEEKLY OPS SUMMARY"
  echo "Host: ${HOST}"
  echo "Role: ${ROLE}"
  echo "Window: ${START} -> ${NOW}"

  section "Uptime / Reboots"
  uptime || true
  last reboot | head -n 10 || true

  section "Disk usage"
  df -hT -P || true
  echo
  df -i -P || true

  section "CPU / Memory (current)"
  echo "-- loadavg --"
  cat /proc/loadavg || true
  echo
  echo "-- free -h --"
  free -h || true
  echo
  echo "-- top cpu processes --"
  ps aux --sort=-%cpu | head -n 15 || true
  echo
  echo "-- top mem processes --"
  ps aux --sort=-%mem | head -n 15 || true

  section "Systemd health"
  echo "-- failed units --"
  systemctl --failed --no-pager || true
  echo
  echo "-- warnings/errors (7d, tail) --"
  journalctl --since "7 days ago" -p warning..alert --no-pager 2>/dev/null | tail -n 300 || true

  section "Auth / SSH signals (7d, tail)"
  journalctl -u ssh --since "7 days ago" --no-pager 2>/dev/null | grep -E "Failed password|Invalid user|Accepted password|Accepted publickey" | tail -n 200 || true
  journalctl -u sshd --since "7 days ago" --no-pager 2>/dev/null | grep -E "Failed password|Invalid user|Accepted password|Accepted publickey" | tail -n 200 || true

  if [[ -n "${CERT_PATHS:-}" ]]; then
    section "Certificate expiry"
    command -v openssl >/dev/null 2>&1 && for p in ${CERT_PATHS}; do
      [[ -f "$p" ]] || continue
      echo "$p: $(openssl x509 -enddate -noout -in "$p" 2>/dev/null || true)"
    done
  fi

  if [[ -n "${BACKUP_OK_FILE:-}" ]]; then
    section "Backup heartbeat"
    if [[ -e "${BACKUP_OK_FILE}" ]]; then
      ls -l "${BACKUP_OK_FILE}" || true
      echo "mtime: $(date -d "@$(stat -c %Y "${BACKUP_OK_FILE}")" -Is 2>/dev/null || true)"
    else
      echo "Missing: ${BACKUP_OK_FILE}"
    fi
  fi

  legacy_health_check
  mail_section
}
)"
subject="WEEKLY OPS SUMMARY ${HOST} (${ROLE})"
send_email "$subject" "$body"
