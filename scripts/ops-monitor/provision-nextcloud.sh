#!/usr/bin/env bash
set -euo pipefail

# Nextcloud provisioning script
# Usage: ./provision-nextcloud.sh

log() { echo "[$(date -Is)] $*"; }

# Pull required images
docker pull nextcloud
docker pull mariadb:10.6

# Create external volumes if not present
docker volume inspect nextcloud_data >/dev/null 2>&1 || docker volume create nextcloud_data
docker volume inspect nextcloud_db >/dev/null 2>&1 || docker volume create nextcloud_db

# Start containers using docker-compose (if available)
if [ -f /opt/nextcloud/docker-compose.yml ]; then
  log "Starting Nextcloud stack via docker-compose..."
  docker-compose -f /opt/nextcloud/docker-compose.yml up -d
else
  log "docker-compose.yml not found. Please place it at /opt/nextcloud/docker-compose.yml."
  exit 1
fi

log "Nextcloud provisioning complete."
