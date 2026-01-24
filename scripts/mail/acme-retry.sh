#!/usr/bin/env bash
set -euo pipefail

MAILCOW_DIR="/opt/mailcow-dockerized"
LOG="/var/log/acme-retry.log"

cd "$MAILCOW_DIR"
docker compose exec acme-mailcow acme-mailcow --force >> "$LOG" 2>&1
