#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="/mnt/Backups"
DEST="$ROOT/cardiq-dev/snapshots"
MODE="${1:---dry-run}"
RETAIN=14

[[ $EUID -eq 0 ]] || exit 1
mountpoint -q "$ROOT" || exit 1
[[ -d "$DEST" && ! -L "$DEST" ]] || exit 1

case "$MODE" in
    --dry-run|--execute) ;;
    *) echo "ERROR: Invalid retention mode"; exit 2 ;;
esac

COUNT=0
PROTECTED=0
EXPIRED=0

while IFS= read -r NAME; do
    [[ "$NAME" =~ ^[0-9]{8}-[0-9]{6}$ ]] || continue

    SNAP="$DEST/$NAME"

    [[ -d "$SNAP" && ! -L "$SNAP" ]] || continue
    [[ -f "$SNAP/VERIFIED" ]] || continue

    if [[ -e "$SNAP/KEEP" || -L "$SNAP/KEEP" ]]; then
        echo "PROTECTED: $NAME"
        PROTECTED=$((PROTECTED + 1))
        continue
    fi

    COUNT=$((COUNT + 1))

    if (( COUNT <= RETAIN )); then
        echo "RETAIN: $NAME"
        continue
    fi

    EXPIRED=$((EXPIRED + 1))

    if [[ "$MODE" == "--execute" ]]; then
        echo "DELETE: $NAME"
        rm -rf --one-file-system -- "$SNAP"
    else
        echo "WOULD DELETE: $NAME"
    fi

done < <(
    find "$DEST" -mindepth 1 -maxdepth 1 \
        -type d -printf '%f\n' | LC_ALL=C sort -r
)

echo "===== RETENTION SUMMARY ====="
echo "Mode: $MODE"
echo "Regular snapshots retained: $((COUNT - EXPIRED))"
echo "Protected snapshots: $PROTECTED"
echo "Expired snapshots: $EXPIRED"
