#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${MONITORING_CONFIG:-/etc/monitoring.env}"
# shellcheck source=/dev/null
source "$CONFIG_FILE"

: "${ALERT_TO:?ALERT_TO is required}"
: "${DISK_THRESHOLD:?DISK_THRESHOLD is required}"
: "${RAM_MIN_FREE:?RAM_MIN_FREE is required}"
: "${SERVICES:?SERVICES is required}"
: "${HEALTH_URL:?HEALTH_URL is required}"

HOST_NAME="$(hostname -s 2>/dev/null || hostname)"
MAIL_MODE="${MAIL_MODE:-auto}"
MAIL_LOG="${MAIL_LOG:-/var/log/web01-alerts.log}"
ALERTS=()

send_alert() {
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

if disk_used=$(df -P / 2>/dev/null | awk 'NR == 2 {gsub(/%/, "", $5); print $5}'); then
    if [[ ! $disk_used =~ ^[0-9]+$ ]]; then
        ALERTS+=("Root filesystem: unable to parse disk usage")
    elif (( disk_used >= DISK_THRESHOLD )); then
        ALERTS+=("Root filesystem usage is ${disk_used}% (threshold: ${DISK_THRESHOLD}%)")
    fi
else
    ALERTS+=("Root filesystem: df probe failed")
fi

if ram_free=$(awk '
    /MemTotal:/ {total=$2}
    /MemAvailable:/ {available=$2}
    END {
        if (total > 0) printf "%.0f", (available * 100) / total;
        else exit 1
    }
' /proc/meminfo 2>/dev/null); then
    if [[ ! $ram_free =~ ^[0-9]+$ ]]; then
        ALERTS+=("RAM: unable to parse available memory")
    elif (( ram_free < RAM_MIN_FREE )); then
        ALERTS+=("Free RAM is ${ram_free}% (minimum: ${RAM_MIN_FREE}%)")
    fi
else
    ALERTS+=("RAM: /proc/meminfo probe failed")
fi

read -r -a service_list <<< "$SERVICES"
for service in "${service_list[@]}"; do
    if ! systemctl is-active --quiet "$service"; then
        ALERTS+=("Service '$service' is not active")
    fi
done

if ! curl -sf --max-time 5 "$HEALTH_URL" >/dev/null; then
    ALERTS+=("Web endpoint is unreachable: $HEALTH_URL")
fi

if (( ${#ALERTS[@]} == 0 )); then
    exit 0
fi

alert_body=$(printf -- '- %s\n' "${ALERTS[@]}")
alert_body="Host: ${HOST_NAME}
Time: $(date -Is)

Problems detected:
${alert_body}"

send_alert "[${HOST_NAME}] HEALTH ALERT" "$alert_body"
exit 1
