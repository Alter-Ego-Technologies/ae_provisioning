#!/usr/bin/env bash
set -euo pipefail

# Wrapper to run both standalone and CyberPanel backup scripts in sequence
# Logs output and errors for each step

LOG_DIR="/mnt/Backups/logs"
mkdir -p "$LOG_DIR"
STAMP=$(date +%F_%H%M%S)
LOG_FILE="$LOG_DIR/all_web_${STAMP}.log"

run_backup() {
  local script="$1"
  local label="$2"
  echo "==== [$(date -Is)] Starting $label backup ====" | tee -a "$LOG_FILE"
  if "$script" >> "$LOG_FILE" 2>&1; then
    echo "==== [$(date -Is)] $label backup SUCCESS ====" | tee -a "$LOG_FILE"
  else
    echo "==== [$(date -Is)] $label backup FAILED ====" | tee -a "$LOG_FILE"
  fi
  echo | tee -a "$LOG_FILE"
}

run_backup "/mnt/Backups/scripts/sync_standalone.sh" "Standalone"
run_backup "/mnt/Backups/scripts/sync_cyberpanel.sh" "CyberPanel"

echo "All webstack-related backups complete. See $LOG_FILE for details."
