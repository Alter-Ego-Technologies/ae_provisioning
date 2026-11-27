#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

export TZ=America/Chicago

LOG_FILE="/mnt/Backups/logs/cardiq-dev-cron.log"

notify_exit() {
    local status=$?
    trap - EXIT

    if (( status == 0 )); then
        /usr/local/sbin/ae-backup/backup_notify.sh \
            cardiq-dev success "$LOG_FILE" || true
    else
        /usr/local/sbin/ae-backup/backup_notify.sh \
            cardiq-dev failure "$LOG_FILE" || true
    fi

    exit "$status"
}

trap notify_exit EXIT

ROOT="/mnt/Backups"
DEST="$ROOT/cardiq-dev"
HEARTBEAT="/var/lib/ops-monitor/backup-success/cardiq_dev"
STAMP="$(date +%Y%m%d-%H%M%S)"
SOURCE="alterego@10.0.1.2:/"

[[ $EUID -eq 0 ]] || exit 1
mountpoint -q "$ROOT" || exit 1

install -d -m 0700 "$DEST"
install -d -m 0700 "$DEST/snapshots"

STAGE="$(mktemp -d "$DEST/.incomplete-${STAMP}-XXXXXX")"
FINAL="$DEST/snapshots/$STAMP"

trap 'echo "ERROR: Card IQ backup failed; incomplete snapshot retained at $STAGE" >&2' ERR

mkdir "$STAGE/files"

cat > "$STAGE/source-paths.txt" <<'PATHS'
usr/local/lsws/conf/vhosts/cardiq-dev/
usr/local/lsws/conf/httpd_config.conf
var/www/cardiq-dev/
usr/local/sbin/cardiq-dev-deploy
usr/local/sbin/cardiq-dev-deploy-preflight
usr/local/lib/cardiq-dev-deploy/
etc/sudoers.d/cardiq-dev-deploy
etc/sudoers.d/cardiq-dev-deploy-alterego
var/backups/cardiq-dev/
var/log/cardiq-dev-deploy/
etc/systemd/system/cardiq-dev-queue.service
etc/systemd/system/multi-user.target.wants/cardiq-dev-queue.service
etc/systemd/system/cardiq-dev-scheduler.service
etc/systemd/system/cardiq-dev-scheduler.timer
etc/systemd/system/timers.target.wants/cardiq-dev-scheduler.timer
PATHS

OPTIONS=(
    -aHrAX
    --numeric-ids
    --relative
    --no-inplace
    --files-from="$STAGE/source-paths.txt"
    -e "ssh -F /etc/ae-backup/ssh_config"
    --rsync-path="sudo -n /usr/bin/rsync"
)

echo "Starting Card IQ recovery backup: $STAMP"

rsync "${OPTIONS[@]}" --stats \
    "$SOURCE" "$STAGE/files/"

echo "Verifying source contents and metadata"

rsync "${OPTIONS[@]}" \
    --dry-run \
    --checksum \
    --itemize-changes \
    --out-format='%i %n%L' \
    "$SOURCE" "$STAGE/files/" \
    > "$STAGE/verification.txt"

if [[ -s "$STAGE/verification.txt" ]]; then
    echo "ERROR: Source verification differences detected"
    exit 1
fi

echo "Generating SHA-256 integrity manifest"

(
    cd "$STAGE/files"
    find . -type f -print0 |
        sort -z |
        xargs -0 -r sha256sum
) > "$STAGE/SHA256SUMS"

(
    cd "$STAGE/files"
    sha256sum --quiet -c "$STAGE/SHA256SUMS"
)

echo "PASS: SHA-256 integrity verification"

printf 'Verified: %s\nSource: %s\n' \
    "$(date -Iseconds)" "$SOURCE" \
    > "$STAGE/VERIFIED"

mv -T -- "$STAGE" "$FINAL"

touch "$HEARTBEAT"

echo "===== AUTOMATIC RETENTION ====="
/usr/local/sbin/ae-backup/retention_cardiq_dev.sh --execute


echo "SUCCESS: Card IQ recovery backup completed"
echo "Snapshot: $FINAL"
