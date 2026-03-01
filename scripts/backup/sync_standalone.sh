#!/usr/bin/env bash
set -e
mountpoint -q /mnt/Backups || { echo "ERROR: /mnt/Backups not mounted"; exit 1; }
exec 9>/tmp/standalone-backup.lock
flock -n 9 || exit 0

STAMP=$(date +%F_%H%M%S)

# Source config from /mnt/Backups/standalone/standalone.conf if present
CONF_PATH="/mnt/Backups/standalone/standalone.conf"
[ -f "$CONF_PATH" ] && source "$CONF_PATH"

# Ensure required variables are set
: "${STANDALONE_DATA_DST:?STANDALONE_DATA_DST is not set}"
: "${STANDALONE_SSH_USER:?STANDALONE_SSH_USER is not set}"

# Ensure destination exists
mkdir -p "${STANDALONE_DATA_DST}"
chmod -R 777 "${STANDALONE_DATA_DST}"
chown -R "${STANDALONE_SSH_USER}:${STANDALONE_SSH_USER}" "${STANDALONE_DATA_DST}"

# Rsync standalone files (do not preserve group to avoid chgrp errors)
rsync -aHAX --no-group --delete -e "ssh -p ${STANDALONE_SSH_PORT}" ${STANDALONE_SSH_USER}@${STANDALONE_PRI}:${STANDALONE_DATA_SRC}/ ${STANDALONE_DATA_DST}/

echo "[INFO] Standalone files backup complete: $STAMP"
