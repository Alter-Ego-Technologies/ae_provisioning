#!/usr/bin/env bash
set -euo pipefail

ROLE="${1:-${SERVER_ROLE:-base}}"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Run as root: sudo scripts/ops-monitor/install.sh [role]" >&2
  exit 1
fi

# Resolve repo root based on this script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

mkdir -p /etc/ops-monitor/roles
mkdir -p /usr/local/sbin
mkdir -p /var/lib/ops-monitor

# Install library + scripts (always overwrite - safe)
install -m 0644 "${REPO_ROOT}/scripts/ops-monitor/bin/ops-monitor-lib.sh" /usr/local/sbin/ops-monitor-lib.sh
install -m 0755 "${REPO_ROOT}/scripts/ops-monitor/bin/ops-threshold-check.sh" /usr/local/sbin/ops-threshold-check
install -m 0755 "${REPO_ROOT}/scripts/ops-monitor/bin/ops-weekly-summary.sh"  /usr/local/sbin/ops-weekly-summary

# Install legacy health check uniformly (always overwrite - safe)
if [[ -f "${REPO_ROOT}/scripts/server_health_check.sh" ]]; then
  install -m 0755 "${REPO_ROOT}/scripts/server_health_check.sh" /usr/local/sbin/server_health_check
fi

# Config: copy only if missing (do NOT clobber real settings)
if [[ ! -f /etc/ops-monitor/ops.conf ]]; then
  install -m 0644 "${REPO_ROOT}/config/ops-monitor/ops.conf" /etc/ops-monitor/ops.conf
  echo "Created /etc/ops-monitor/ops.conf (edit OPS_TO/OPS_FROM!)"
else
  echo "Keeping existing /etc/ops-monitor/ops.conf"
fi

# Role file
echo "${ROLE}" > /etc/ops-monitor/role
chmod 0644 /etc/ops-monitor/role

# Role overlays (safe to overwrite from repo; local overrides belong in /etc/ops-monitor/local.conf)
install -m 0644 "${REPO_ROOT}/config/ops-monitor/roles/"*.conf /etc/ops-monitor/roles/ 2>/dev/null || true

# systemd units (always overwrite - safe)
install -m 0644 "${REPO_ROOT}/scripts/ops-monitor/systemd/ops-threshold-check.service" /etc/systemd/system/ops-threshold-check.service
install -m 0644 "${REPO_ROOT}/scripts/ops-monitor/systemd/ops-threshold-check.timer"   /etc/systemd/system/ops-threshold-check.timer
install -m 0644 "${REPO_ROOT}/scripts/ops-monitor/systemd/ops-weekly-summary.service" /etc/systemd/system/ops-weekly-summary.service
install -m 0644 "${REPO_ROOT}/scripts/ops-monitor/systemd/ops-weekly-summary.timer"   /etc/systemd/system/ops-weekly-summary.timer

systemctl daemon-reload
systemctl enable --now ops-threshold-check.timer ops-weekly-summary.timer

echo "Installed ops-monitor. Role=${ROLE}"
echo "Next:"
echo "  sudoedit /etc/ops-monitor/ops.conf"
echo "  sudo /usr/local/sbin/ops-threshold-check"
echo "  sudo /usr/local/sbin/ops-weekly-summary"
