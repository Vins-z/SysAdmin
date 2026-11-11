#!/usr/bin/env bash
# ==============================================================================
# Script Name: service_health.sh
# Description: Automated service health inspection and self-healing watchdog.
# Supported:   Ubuntu Linux (systemd) & POSIX process checking fallback.
# ==============================================================================

set -euo pipefail

DEFAULT_SERVICES=("nginx" "docker" "ssh" "cron")
SERVICES=("${DEFAULT_SERVICES[@]}")
AUTO_RESTART=true
MAX_RETRIES=2
RETRY_DELAY=2
LOG_DIR="${LOG_DIR:-/var/log/serveradmin}"
LOG_FILE="${LOG_DIR}/service_health.log"
JSON_OUTPUT=false
DRY_RUN=false

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] [service1 service2 ...]

Options:
    -s, --services "svc1 svc2"   Space-separated list of services to check
    --no-restart                 Disable automatic restart attempts on failure
    -r, --retries <number>       Maximum restart retries (Default: 2)
    -l, --log <file_path>        Path to log file (Default: /var/log/serveradmin/service_health.log)
    -j, --json                   Output status in JSON format
    -d, --dry-run                Perform check without triggering restart actions
    -h, --help                   Display this help message and exit

Examples:
    $(basename "$0") nginx docker ssh
    $(basename "$0") --no-restart --json
EOF
    exit 0
}

# Parse Arguments
POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--services)
            read -r -a SERVICES <<< "$2"
            shift 2
            ;;
        --no-restart)
            AUTO_RESTART=false
            shift
            ;;
        -r|--retries)
            MAX_RETRIES="$2"
            shift 2
            ;;
        -l|--log)
            LOG_FILE="$2"
            LOG_DIR="$(dirname "$LOG_FILE")"
            shift 2
            ;;
        -j|--json)
            JSON_OUTPUT=true
            shift
            ;;
        -d|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            POSITIONAL_ARGS+=("$1")
            shift
            ;;
    esac
done

if [ ${#POSITIONAL_ARGS[@]} -gt 0 ]; then
    SERVICES=("${POSITIONAL_ARGS[@]}")
fi

init_logging() {
    if [ "$DRY_RUN" = false ]; then
        if [ ! -d "$LOG_DIR" ]; then
            mkdir -p "$LOG_DIR" 2>/dev/null || LOG_FILE="/tmp/service_health.log"
        fi
        touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/service_health.log"
    fi
}

log_message() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    if [ "$DRY_RUN" = false ]; then
        echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
        if command -v logger >/dev/null 2>&1; then
            logger -t "serveradmin-health" "[$level] $message" 2>/dev/null || true
        fi
    fi

    if [ "$JSON_OUTPUT" = false ]; then
        case "$level" in
            CRITICAL|FAILED)
                echo -e "${RED}[$timestamp] [$level]${NC} $message" >&2
                ;;
            RECOVERED|WARNING)
                echo -e "${YELLOW}[$timestamp] [$level]${NC} $message"
                ;;
            OK|INFO)
                echo -e "${GREEN}[$timestamp] [$level]${NC} $message"
                ;;
            *)
                echo "[$timestamp] [$level] $message"
                ;;
        esac
    fi
}

check_service_status() {
    local svc="$1"
    # Check managed PID file
    for pdir in "./data/services" "/opt/serveradmin/data/services" "/tmp/serveradmin/services"; do
        local pfile="${pdir}/${svc}.pid"
        if [ -f "$pfile" ]; then
            local pid
            pid=$(cat "$pfile" 2>/dev/null || true)
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                echo "active"
                return 0
            fi
        fi
    done

    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            echo "active"
        else
            echo "inactive"
        fi
    else
        # Process table fallback for non-systemd / testing environments
        if pgrep -f "$svc" >/dev/null 2>&1 || ps -A 2>/dev/null | grep -v grep | grep -q "$svc"; then
            echo "active"
        else
            echo "inactive"
        fi
    fi
}

restart_service() {
    local svc="$1"
    if [ "$DRY_RUN" = true ]; then
        log_message "INFO" "[DRY-RUN] Would attempt restart for service '$svc'"
        return 0
    fi

    local attempt=1
    while [ $attempt -le "$MAX_RETRIES" ]; do
        log_message "WARNING" "Attempting restart for service '$svc' (Attempt $attempt of $MAX_RETRIES)..."

        if command -v systemctl >/dev/null 2>&1; then
            if systemctl restart "$svc" 2>/dev/null; then
                sleep "$RETRY_DELAY"
                if [ "$(check_service_status "$svc")" = "active" ]; then
                    log_message "RECOVERED" "Service '$svc' successfully restarted and active."
                    return 0
                fi
            fi
        fi

        attempt=$((attempt + 1))
        sleep "$RETRY_DELAY"
    done

    log_message "CRITICAL" "Service '$svc' failed to restart after $MAX_RETRIES attempts."
    return 1
}

main() {
    init_logging
    local failed_count=0
    local json_records=()

    if [ "$JSON_OUTPUT" = false ]; then
        echo -e "${BLUE}=== Service Health Inspection ===${NC}"
    fi

    for svc in "${SERVICES[@]}"; do
        local status
        status=$(check_service_status "$svc")

        if [ "$status" = "active" ]; then
            log_message "OK" "Service '$svc' is healthy and running."
            if [ "$JSON_OUTPUT" = true ]; then
                json_records+=("{\"service\":\"$svc\",\"status\":\"active\",\"recovered\":false}")
            fi
        else
            log_message "FAILED" "Service '$svc' is DOWN or inactive!"
            local recovered=false

            if [ "$AUTO_RESTART" = true ] && [ "$DRY_RUN" = false ]; then
                if restart_service "$svc"; then
                    recovered=true
                    status="recovered"
                else
                    failed_count=$((failed_count + 1))
                fi
            else
                failed_count=$((failed_count + 1))
            fi

            if [ "$JSON_OUTPUT" = true ]; then
                json_records+=("{\"service\":\"$svc\",\"status\":\"$status\",\"recovered\":$recovered}")
            fi
        fi
    done

    if [ "$JSON_OUTPUT" = true ]; then
        local IFS=","
        echo "{\"timestamp\":\"$(date '+%Y-%m-%dT%H:%M:%SZ')\",\"overall_status\":\"$([ "$failed_count" -eq 0 ] && echo "ALL_SERVICES_OK" || echo "SERVICES_DEGRADED")\",\"failed_count\":$failed_count,\"services\":[${json_records[*]}]}"
    else
        echo ""
        if [ "$failed_count" -eq 0 ]; then
            echo -e "${GREEN}✓ All inspected services are operational.${NC}"
        else
            echo -e "${RED}⚠ $failed_count service(s) currently unrecovered or down. Check $LOG_FILE${NC}"
        fi
    fi

    if [ "$failed_count" -gt 0 ]; then
        return 1
    else
        return 0
    fi
}

main
