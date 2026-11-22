#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Central Mailcow recovery backup orchestrator.
# Runs on AE-Backups as gabe.
#
# Usage:
#   backup_mailcow_official.sh daily
#   backup_mailcow_official.sh full

ROOT="/mnt/Backups"
DEST="$ROOT/mailcow-official"
LOG_DIR="$ROOT/logs"
LOCK="$ROOT/.mailcow-official.lock"

REMOTE_USER="gabe"
REMOTE_HOST="10.0.0.2"
REMOTE_PORT="2222"
SSH_KEY="/home/gabe/.ssh/id_ed25519"

MAILCOW_DIR="/opt/mailcow-dockerized"
STAGING="/var/lib/docker/mailcow-backup-automated"
B2_REMOTE="b2crypt:mailcow-official"

MODE="${1:-}"
case "$MODE" in
  daily|full) ;;
  *)
    echo "Usage: $0 {daily|full}" >&2
    exit 2
    ;;
esac

mountpoint -q "$ROOT" || {
  echo "ERROR: Backup volume is not mounted" >&2
  exit 1
}

mkdir -p "$DEST" "$LOG_DIR"

exec 9>"$LOCK"
flock -n 9 || {
  echo "Another official Mailcow backup is running."
  exit 1
}

STAMP="$(date -u +%Y-%m-%d_%H%M%S)"
RUN_ID="automated-${MODE}-${STAMP}-$$"
LOG="$LOG_DIR/mailcow_official_${RUN_ID}.log"
WORK="$DEST/.${RUN_ID}.partial"
FINAL="$DEST/$RUN_ID"
REMOTE_RUN="$STAGING/$RUN_ID"

log() {
  printf '[%s] %s\n' "$(date -u '+%F %T UTC')" "$*" |
    tee -a "$LOG"
}

fail() {
  log "ERROR: $*"
  exit 1
}

on_exit() {
  status=$?
  if (( status != 0 )); then
    log "FAILED (exit $status). Staging and partial files retained."
    log "Remote staging: $REMOTE_RUN"
    log "Local staging: $WORK"
  fi
}
trap on_exit EXIT

SSH_OPTS=(
  -p "$REMOTE_PORT"
  -i "$SSH_KEY"
  -o BatchMode=yes
  -o IdentitiesOnly=yes
  -o ConnectTimeout=15
  -o StrictHostKeyChecking=yes
)

remote() {
  ssh "${SSH_OPTS[@]}" \
    "$REMOTE_USER@$REMOTE_HOST" "$@"
}

log "Starting Mailcow $MODE backup"

# A full snapshot requires sufficient working space.
# 25 GiB is a conservative starting threshold.
if [[ "$MODE" == "full" ]]; then
  FREE_KIB="$(df -Pk "$ROOT" | awk 'NR==2 {print $4}')"
  (( FREE_KIB >= 25 * 1024 * 1024 )) ||
    fail "Insufficient free space for full backup (minimum 25 GiB)"
fi

command -v rsync >/dev/null || fail "rsync missing"
command -v zstd >/dev/null || fail "zstd missing"
command -v rclone >/dev/null || fail "rclone missing"
command -v sha256sum >/dev/null || fail "sha256sum missing"

remote 'sudo -n true' ||
  fail "Remote passwordless sudo unavailable"

rclone lsf b2crypt: >/dev/null ||
  fail "Encrypted B2 remote unavailable"

[[ ! -e "$WORK" && ! -e "$FINAL" ]] ||
  fail "Local run directory already exists"

mkdir -m 700 "$WORK"

# Each run gets its own remote directory.
# Mailcow itself creates a timestamped child beneath it.
remote "sudo -n mkdir -m 755 '$REMOTE_RUN'" ||
  fail "Cannot create remote staging"

log "Running official Mailcow backup on Mailadmin"

if [[ "$MODE" == "full" ]]; then
  COMPONENT="all"
else
  COMPONENT="mysql"
fi

# The official script may not propagate every component failure.
# Archive validation below is therefore mandatory.
remote \
  "cd '$MAILCOW_DIR' &&
   sudo -n env MAILCOW_BACKUP_LOCATION='$REMOTE_RUN' \
   bash helper-scripts/backup_and_restore.sh backup '$COMPONENT'" \
   >> "$LOG" 2>&1 ||
  fail "Official Mailcow backup command failed"

log "Locating official backup snapshot"

SNAPSHOT="$(
  remote "sudo -n find '$REMOTE_RUN' \
    -mindepth 1 -maxdepth 1 -type d -name 'mailcow-*' \
    -printf '%f\n'" |
  tr -d '\r'
)"

[[ -n "$SNAPSHOT" ]] ||
  fail "Official Mailcow snapshot missing"

[[ "$SNAPSHOT" != *$'\n'* ]] ||
  fail "Unexpected multiple Mailcow snapshots"

[[ "$SNAPSHOT" =~ ^mailcow-[0-9-]+$ ]] ||
  fail "Unexpected snapshot name"

log "Snapshot: $SNAPSHOT"

# Create a comprehensive configuration archive remotely.
# This includes custom configuration, TLS private keys,
# and the deployment's compose configuration.
log "Creating comprehensive configuration archive"

remote \
  "sudo -n tar -C '$MAILCOW_DIR' \
    -czpf '$REMOTE_RUN/$SNAPSHOT/backup_configuration.tar.gz' \
    mailcow.conf \
    docker-compose.yml \
    docker-compose.override.yml \
    data/conf \
    data/assets/ssl" \
  >> "$LOG" 2>&1 ||
  fail "Configuration archive failed"

log "Transferring archives to AE-Backups"

RSYNC_SSH=(
  ssh
  "${SSH_OPTS[@]}"
)

printf -v RSYNC_RSH '%q ' "${RSYNC_SSH[@]}"

rsync -a --partial \
  -e "$RSYNC_RSH" \
  --rsync-path="sudo -n /usr/bin/rsync" \
  "$REMOTE_USER@$REMOTE_HOST:$REMOTE_RUN/$SNAPSHOT/" \
  "$WORK/" >> "$LOG" 2>&1 ||
  fail "Archive transfer failed"

log "Validating required files"

required=(
  mailcow.conf
  backup_mariadb.tar.zst
  backup_configuration.tar.gz
)

if [[ "$MODE" == "full" ]]; then
  required+=(
    backup_vmail.tar.zst
    backup_crypt.tar.zst
    backup_redis.tar.zst
    backup_rspamd.tar.zst
    backup_postfix.tar.zst
  )
fi

for file in "${required[@]}"; do
  [[ -s "$WORK/$file" ]] ||
    fail "Missing or empty archive: $file"
done

log "Testing compressed archives"

for file in "${required[@]}"; do
  case "$file" in
    *.tar.zst)
      zstd -tq "$WORK/$file" ||
        fail "Zstandard integrity failed: $file"
      tar --use-compress-program=zstd -tf "$WORK/$file" \
        >/dev/null ||
        fail "Tar integrity failed: $file"
      ;;
    *.tar.gz)
      tar -tzf "$WORK/$file" >/dev/null ||
        fail "Tar integrity failed: $file"
      ;;
  esac
done

# Verify local copies against the remote staging files
# before committing the snapshot.
log "Comparing transferred archives with Mailadmin"

for file in "${required[@]}"; do
  LOCAL_HASH="$(sha256sum "$WORK/$file" | awk '{print $1}')"

  REMOTE_HASH="$(
    remote "sudo -n sha256sum '$REMOTE_RUN/$SNAPSHOT/$file'" |
      awk '{print $1}'
  )"

  [[ "$LOCAL_HASH" == "$REMOTE_HASH" ]] ||
    fail "Checksum mismatch: $file"
done

log "Validating prepared MariaDB backup"

CHECKPOINT="$(
  tar --absolute-names \
    --use-compress-program=zstd \
    -xOf "$WORK/backup_mariadb.tar.zst" \
    /backup_mariadb/xtrabackup_checkpoints
)" || fail "Cannot read MariaDB backup checkpoint"

grep -Eq '^[[:space:]]*backup_type[[:space:]]*=[[:space:]]*log-applied[[:space:]]*$' \
  <<< "$CHECKPOINT" ||
  fail "MariaDB backup was not successfully prepared"

log "MariaDB checkpoint verified: log-applied"

log "Writing checksum manifest"

(
  cd "$WORK"
  sha256sum "${required[@]}" > SHA256SUMS
)

# Commit locally only after all checks pass.
mv "$WORK" "$FINAL"

log "Uploading encrypted backup to B2"

rclone copy "$FINAL" "$B2_REMOTE/$RUN_ID" \
  --transfers 2 \
  --checkers 4 \
  --retries 3 \
  >> "$LOG" 2>&1 ||
  fail "Encrypted B2 upload failed"

log "Verifying encrypted B2 backup by download"

rclone check "$FINAL" "$B2_REMOTE/$RUN_ID" \
  --download \
  --one-way \
  >> "$LOG" 2>&1 ||
  fail "B2 download verification failed"

log "B2 verification passed"

# Delete only this run's remote staging directory.
# No wildcards, retention cleanup, or deletion of old snapshots.
log "Removing verified temporary Mailadmin staging"

# Validate the exact staging path before removal.
[[ "$RUN_ID" =~ ^automated-(daily|full)-[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}-[0-9]+$ ]] ||
  fail "Unsafe backup run identifier"

[[ "$REMOTE_RUN" == "$STAGING/$RUN_ID" ]] ||
  fail "Unsafe remote staging path"

remote "sudo -n test -d '$REMOTE_RUN' &&
        sudo -n rm -rf -- '$REMOTE_RUN'" ||
  fail "Verified backup succeeded, but remote staging cleanup failed"

# Retain only the two newest automated full snapshots locally.
# This runs only after the current backup passes encrypted B2 verification.
# Historical recovery snapshots and daily database backups are excluded.
if [[ "$MODE" == "full" ]]; then
  log "Applying local full-backup retention (keep 2)"

  # Detect failures in the retention enumeration pipeline.
  if ! OLD_FULLS_OUTPUT="$(
    find "$DEST" -regextype posix-extended \
      -mindepth 1 -maxdepth 1 -type d \
      -regex '.*/automated-full-[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}-[0-9]+' \
      -printf '%f\n' |
    sort -r |
    tail -n +3
  )"; then
    fail "Unable to enumerate local full backups for retention"
  fi

  OLD_FULLS=()
  if [[ -n "$OLD_FULLS_OUTPUT" ]]; then
    mapfile -t OLD_FULLS <<< "$OLD_FULLS_OUTPUT"
  fi
  for OLD in "${OLD_FULLS[@]}"; do
    [[ "$OLD" =~ ^automated-full-[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}-[0-9]+$ ]] ||
      fail "Unsafe retention target"

    [[ "$OLD" != "$RUN_ID" ]] ||
      fail "Refusing to remove current backup"

    log "Verifying older backup in encrypted B2: $OLD"

    if ! rclone check "$DEST/$OLD" "$B2_REMOTE/$OLD" \
      --download --one-way >> "$LOG" 2>&1; then
      log "WARNING: B2 verification failed for $OLD; retaining local backup"
      continue
    fi

    log "Removing older verified local full backup: $OLD"
    rm -rf -- "$DEST/$OLD"
  done
fi

log "SUCCESS: Mailcow $MODE backup completed"
# Update full-backup heartbeat only after verified full backups.
if [[ "$MODE" == "full" ]]; then
  touch /var/lib/ops-monitor/backup-success/mailcow_full
fi
log "Local: $FINAL"
log "Encrypted B2: $B2_REMOTE/$RUN_ID"
