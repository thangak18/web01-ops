#!/usr/bin/env bash
set -euo pipefail
set -E

CONFIG_FILE="${BACKUP_CONFIG:-/etc/backup.env}"
# shellcheck source=/dev/null
source "$CONFIG_FILE"

: "${DATA_DIR:?DATA_DIR is required}"
: "${ALERT_TO:?ALERT_TO is required}"
: "${DEST:?DEST is required}"
: "${RETAIN_DAYS:?RETAIN_DAYS is required}"

DATA_DIR="${DATA_DIR/#\~/$HOME}"
DEST="${DEST/#\~/$HOME}"
HOST_NAME="$(hostname -s 2>/dev/null || hostname)"
MAIL_MODE="${MAIL_MODE:-auto}"
MAIL_LOG="${MAIL_LOG:-/var/log/web01-alerts.log}"
WORK_DIR=""
ERROR_REPORTED=0

send_email() {
    local subject=$1
    local body=$2

    case "$MAIL_MODE" in
        log)
            {
                printf '%s\n' "--- $(date -Is) ---"
                printf 'To: %s\nSubject: %s\n\n%s\n' "$ALERT_TO" "$subject" "$body"
            } >> "$MAIL_LOG"
            ;;
        msmtp)
            printf 'To: %s\nSubject: %s\n\n%s\n' "$ALERT_TO" "$subject" "$body" | msmtp "$ALERT_TO"
            ;;
        mail)
            printf '%s\n' "$body" | mail -s "$subject" "$ALERT_TO"
            ;;
        auto)
            if command -v msmtp >/dev/null 2>&1; then
                printf 'To: %s\nSubject: %s\n\n%s\n' "$ALERT_TO" "$subject" "$body" | msmtp "$ALERT_TO"
            elif command -v mail >/dev/null 2>&1; then
                printf '%s\n' "$body" | mail -s "$subject" "$ALERT_TO"
            else
                {
                    printf '%s\n' "--- $(date -Is) ---"
                    printf 'To: %s\nSubject: %s\n\n%s\n' "$ALERT_TO" "$subject" "$body"
                } >> "$MAIL_LOG"
            fi
            ;;
        *)
            printf 'Unsupported MAIL_MODE: %s\n' "$MAIL_MODE" >&2
            return 2
            ;;
    esac
}

on_error() {
    local exit_code=$?
    local line_number=$1
    local failed_command=$2

    ERROR_REPORTED=1
    set +e
    send_email \
        "[${HOST_NAME}] BACKUP FAILED" \
        "Host: ${HOST_NAME}
Time: $(date -Is)
Exit code: ${exit_code}
Line: ${line_number}
Command: ${failed_command}"
    set -e
    return 0
}

cleanup() {
    local exit_code=$?
    trap - ERR
    set +e

    if (( exit_code != 0 && ERROR_REPORTED == 0 )); then
        send_email \
            "[${HOST_NAME}] BACKUP FAILED" \
            "Host: ${HOST_NAME}
Time: $(date -Is)
Exit code: ${exit_code}
The backup stopped before completion."
    fi

    if [[ -n $WORK_DIR && -d $WORK_DIR ]]; then
        rm -rf -- "$WORK_DIR"
    fi

    exit "$exit_code"
}

trap 'on_error $LINENO "$BASH_COMMAND"' ERR
trap cleanup EXIT

if [[ ! -d $DATA_DIR ]]; then
    printf 'Data directory does not exist: %s\n' "$DATA_DIR" >&2
    false
fi

if [[ ! $RETAIN_DAYS =~ ^[0-9]+$ ]]; then
    printf 'RETAIN_DAYS must be a non-negative integer\n' >&2
    false
fi

WORK_DIR="$(mktemp -d -t web01-backup.XXXXXX)"
PAYLOAD_DIR="$WORK_DIR/payload"
mkdir -p "$PAYLOAD_DIR/data"

# Copy only the data that belongs in the backup. The tar-to-tar pipeline preserves
# permissions and avoids requiring rsync on the source host.
tar --exclude='*.log' --exclude='*.tmp' -C "$DATA_DIR" -cf - . \
    | tar -C "$PAYLOAD_DIR/data" -xf -

(
    cd "$PAYLOAD_DIR/data"
    while IFS= read -r -d '' file; do
        md5sum "$file"
    done < <(find . -type f -print0 | sort -z)
) > "$PAYLOAD_DIR/manifest.txt"

if [[ ${FORCE_FAILURE:-false} == true ]]; then
    # Task 3 demonstration: this real fault must trigger ERR and stop the script.
    tar -czf "$WORK_DIR/forced-error.tgz" /no/such/dir
    printf 'THIS LINE MUST NOT RUN\n'
fi

TIMESTAMP="$(date +'%Y%m%d-%H%M%S')"
ARCHIVE_NAME="web01-backup-${HOST_NAME}-${TIMESTAMP}.tar.gz"
ARCHIVE_PATH="$WORK_DIR/$ARCHIVE_NAME"

tar -C "$PAYLOAD_DIR" -czf "$ARCHIVE_PATH" manifest.txt data
tar -tzf "$ARCHIVE_PATH" >/dev/null

is_remote_dest() {
    [[ $DEST == *:* && $DEST != /* ]]
}

if is_remote_dest; then
    remote_host=${DEST%%:*}
    remote_path=${DEST#*:}
    printf -v quoted_remote_path '%q' "$remote_path"
    printf -v quoted_partial '%q' "$remote_path/${ARCHIVE_NAME}.partial"
    printf -v quoted_final '%q' "$remote_path/$ARCHIVE_NAME"

    # shellcheck disable=SC2029 -- values are safely shell-escaped with printf %q.
    ssh "$remote_host" "mkdir -p -- $quoted_remote_path"
    if command -v rsync >/dev/null 2>&1; then
        rsync -az -- "$ARCHIVE_PATH" "$remote_host:$remote_path/${ARCHIVE_NAME}.partial"
    else
        scp -- "$ARCHIVE_PATH" "$remote_host:$remote_path/${ARCHIVE_NAME}.partial"
    fi
    # shellcheck disable=SC2029 -- values are safely shell-escaped with printf %q.
    ssh "$remote_host" "mv -- $quoted_partial $quoted_final"
    # shellcheck disable=SC2029 -- values are safely shell-escaped with printf %q.
    ssh "$remote_host" \
        "find $quoted_remote_path -maxdepth 1 -type f -name 'web01-backup-*.tar.gz' -mtime +$RETAIN_DAYS -delete"
else
    mkdir -p -- "$DEST"
    cp -- "$ARCHIVE_PATH" "$DEST/${ARCHIVE_NAME}.partial"
    mv -- "$DEST/${ARCHIVE_NAME}.partial" "$DEST/$ARCHIVE_NAME"
    find "$DEST" -maxdepth 1 -type f -name 'web01-backup-*.tar.gz' \
        -mtime "+$RETAIN_DAYS" -delete
fi

archive_size=$(du -h "$ARCHIVE_PATH" | awk '{print $1}')
send_email \
    "[${HOST_NAME}] Backup OK" \
    "Host: ${HOST_NAME}
Time: $(date -Is)
Archive: ${ARCHIVE_NAME}
Size: ${archive_size}
Destination: ${DEST}"

printf 'Backup OK: %s (%s) -> %s\n' "$ARCHIVE_NAME" "$archive_size" "$DEST"
