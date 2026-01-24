#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Run as root: sudo scripts/ops-monitor/uninstall.sh" >&2
  exit 1
fi

systemctl disable --now ops-threshold-check.timer ops-weekly-summary.timer 2>/dev/null || true
rm -f /etc/systemd/system/ops-threshold-check.* /etc/systemd/system/ops-weekly-summary.* 2>/dev/null || true
systemctl daemon-reload

rm -f /usr/local/sbin/ops-threshold-check \
      /usr/local/sbin/ops-weekly-summary \
      /usr/local/sbin/ops-monitor-lib.sh \
      /usr/local/sbin/server_health_check 2>/dev/null || true

echo "Left /etc/ops-monitor and /var/lib/ops-monitor in place."
echo "Remove them manually if you want a full wipe."
