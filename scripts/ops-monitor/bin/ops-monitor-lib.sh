#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date -Is)] $*"; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Must run as root." >&2
    exit 1
  fi
}

# Load config layers:
#  1) /etc/ops-monitor/ops.conf
#  2) /etc/ops-monitor/roles/base.conf
#  3) /etc/ops-monitor/roles/$ROLE.conf (ROLE from /etc/ops-monitor/role)
#  4) /etc/ops-monitor/local.conf (optional, per-host overrides)
load_config() {
  local conf="/etc/ops-monitor/ops.conf"
  if [[ ! -f "$conf" ]]; then
    echo "Missing $conf. Did you run install?" >&2
    exit 1
  fi

  # shellcheck disable=SC1090
  source "$conf"

  ROLE="base"
  if [[ -f /etc/ops-monitor/role ]]; then
    ROLE="$(tr -d ' \n\r\t' < /etc/ops-monitor/role)"
    [[ -z "$ROLE" ]] && ROLE="base"
  fi

  if [[ -f /etc/ops-monitor/roles/base.conf ]]; then
    # shellcheck disable=SC1091
    source /etc/ops-monitor/roles/base.conf
  fi
  if [[ -f "/etc/ops-monitor/roles/${ROLE}.conf" ]]; then
    # shellcheck disable=SC1090
    source "/etc/ops-monitor/roles/${ROLE}.conf"
  fi
  if [[ -f /etc/ops-monitor/local.conf ]]; then
    # shellcheck disable=SC1091
    source /etc/ops-monitor/local.conf
  fi

  STATE_DIR="${STATE_DIR:-/var/lib/ops-monitor}"
  mkdir -p "$STATE_DIR"
}

hostname_fqdn() {
  hostname -f 2>/dev/null || hostname
}

send_email() {
  local subject="$1"
  local body="$2"

  local to="${OPS_TO:?OPS_TO not set}"
  local from="${OPS_FROM:?OPS_FROM not set}"
  local prefix="${OPS_SUBJECT_PREFIX:-}"

  /usr/sbin/sendmail -t <<EOF
To: ${to}
From: ${from}
Subject: ${prefix} ${subject}
Content-Type: text/plain; charset=UTF-8

${body}
EOF
}

# State file helpers (key=value lines)
state_file() { echo "${STATE_DIR}/state.env"; }

state_get() {
  local key="$1"
  local f; f="$(state_file)"
  [[ -f "$f" ]] || return 1
  grep -E "^${key}=" "$f" | tail -n1 | sed -E "s/^${key}=//"
}

state_set() {
  local key="$1"
  local val="$2"
  local f; f="$(state_file)"
  touch "$f"
  grep -v -E "^${key}=" "$f" > "${f}.tmp" || true
  echo "${key}=${val}" >> "${f}.tmp"
  mv "${f}.tmp" "$f"
}

cooldown_ok() {
  local key="$1"
  local now cooldown_s epoch_last
  now="$(date +%s)"
  cooldown_s=$(( (${ALERT_COOLDOWN_MIN:-60}) * 60 ))
  epoch_last="$(state_get "lastsent_${key}" 2>/dev/null || echo 0)"
  if (( now - epoch_last >= cooldown_s )); then
    return 0
  fi
  return 1
}

mark_sent() {
  local key="$1"
  state_set "lastsent_${key}" "$(date +%s)"
}

status_rank() {
  case "$1" in
    OK) echo 0 ;;
    WARN) echo 1 ;;
    CRIT) echo 2 ;;
    *) echo 3 ;;
  esac
}
