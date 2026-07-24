#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${BACKUP_CONFIG:-/etc/backup.env}"
# shellcheck source=/dev/null
source "$CONFIG_FILE"

: "${DEST:?DEST is required}"

DEST="${DEST/#\~/$HOME}"
WORK_DIR="$(mktemp -d -t web01-restore.XXXXXX)"
ARCHIVE_PATH=""

cleanup() {
    local exit_code=$?
    rm -rf -- "$WORK_DIR"
    exit "$exit_code"
}
trap cleanup EXIT

is_remote_dest() {
    [[ $DEST == *:* && $DEST != /* ]]
}

if is_remote_dest; then
    remote_host=${DEST%%:*}
    remote_path=${DEST#*:}
    printf -v quoted_remote_path '%q' "$remote_path"

    # shellcheck disable=SC2029 -- remote_path is safely shell-escaped with printf %q.
    latest_name=$(ssh "$remote_host" \
        "find $quoted_remote_path -maxdepth 1 -type f -name 'web01-backup-*.tar.gz' -printf '%T@ %f\\n' | sort -nr | awk 'NR==1 {print \$2}'")

    if [[ -z $latest_name ]]; then
        printf 'No backup archives found at %s\n' "$DEST" >&2
        exit 1
    fi

    ARCHIVE_PATH="$WORK_DIR/$latest_name"
    if command -v rsync >/dev/null 2>&1; then
        rsync -az -- "$remote_host:$remote_path/$latest_name" "$ARCHIVE_PATH"
    else
        scp -- "$remote_host:$remote_path/$latest_name" "$ARCHIVE_PATH"
    fi
else
    latest_path=$(find "$DEST" -maxdepth 1 -type f -name 'web01-backup-*.tar.gz' \
        -printf '%T@ %p\n' | sort -nr | awk 'NR==1 {$1=""; sub(/^ /, ""); print}')

    if [[ -z $latest_path ]]; then
        printf 'No backup archives found in %s\n' "$DEST" >&2
        exit 1
    fi

    ARCHIVE_PATH="$latest_path"
fi

EXTRACT_DIR="$WORK_DIR/extracted"
VERIFY_LOG="$WORK_DIR/verify.log"
mkdir -p "$EXTRACT_DIR"
tar -xzf "$ARCHIVE_PATH" -C "$EXTRACT_DIR"

if [[ ! -f $EXTRACT_DIR/manifest.txt || ! -d $EXTRACT_DIR/data ]]; then
    printf 'Archive is missing manifest.txt or data/\n' >&2
    exit 1
fi

if (
    cd "$EXTRACT_DIR/data"
    md5sum -c ../manifest.txt
) | tee "$VERIFY_LOG"; then
    matched=$(grep -c ': OK$' "$VERIFY_LOG" || true)
    expected=$(wc -l < "$EXTRACT_DIR/manifest.txt")
    printf 'Restore test PASSED: %s/%s files matched for %s\n' \
        "$matched" "$expected" "$(basename "$ARCHIVE_PATH")"
else
    failed=$(grep -c ': FAILED$' "$VERIFY_LOG" || true)
    printf 'Restore test FAILED: %s file(s) did not match\n' "$failed" >&2
    exit 1
fi
