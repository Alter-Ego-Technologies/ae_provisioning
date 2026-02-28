#!/usr/bin/env bash
set -e
mountpoint -q /mnt/Backups || { echo "ERROR: /mnt/Backups not mounted"; exit 1; }
exec 9>/tmp/customapps-backup.lock
flock -n 9 || exit 0

STAMP=$(date +%F_%H%M%S)

 # Source config from /mnt/Backups/CustomApps/CustomApps.conf if present
CONF_PATH="/mnt/Backups/CustomApps/CustomApps.conf"
[ -f "$CONF_PATH" ] && source "$CONF_PATH"

# Ensure required variables are set
: "${CUSTOMAPPS_DATA_DST:?CUSTOMAPPS_DATA_DST is not set}"
: "${CUSTOMAPPS_SSH_USER:?CUSTOMAPPS_SSH_USER is not set}"

# Ensure destination exists
mkdir -p "${CUSTOMAPPS_DATA_DST}"
chmod -R 777 "${CUSTOMAPPS_DATA_DST}"
chown -R "${CUSTOMAPPS_SSH_USER}:${CUSTOMAPPS_SSH_USER}" "${CUSTOMAPPS_DATA_DST}"

# Rsync CustomApps files (do not preserve group to avoid chgrp errors)
rsync -aHAX --no-group --delete -e "ssh -p ${CUSTOMAPPS_SSH_PORT}" ${CUSTOMAPPS_SSH_USER}@${CUSTOMAPPS_PRI}:${CUSTOMAPPS_DATA_SRC}/ ${CUSTOMAPPS_DATA_DST}/

echo "[INFO] CustomApps files backup complete: $STAMP"