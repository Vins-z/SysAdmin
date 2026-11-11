#!/usr/bin/env bash
# ==============================================================================
# Script Name: disk_monitor.sh
# Description: Automated disk space and inode monitoring with alerting and logging.
# Supported:   Ubuntu Linux (primary) & POSIX-compliant systems.
# ==============================================================================

set -euo pipefail

# Default Configuration
WARN_THRESHOLD=80
CRIT_THRESHOLD=90
INODE_WARN_THRESHOLD=85
LOG_DIR="${LOG_DIR:-/var/log/serveradmin}"
LOG_FILE="${LOG_DIR}/disk_monitor.log"
ALERT_EMAIL="${ALERT_EMAIL:-}"
DRY_RUN=false
JSON_OUTPUT=false

# ANSI Color Codes
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
    -w, --warn <percent>     Warning threshold percentage (Default: 80)
    -c, --crit <percent>     Critical threshold percentage (Default: 90)
    -i, --inode <percent>    Inode warning threshold percentage (Default: 85)
    -l, --log <file_path>    Path to log file (Default: /var/log/serveradmin/disk_monitor.log)
    -j, --json               Output results in JSON format
    -d, --dry-run            Simulate check without writing to system log directory
    -h, --help               Display this help message and exit

Examples:
    $(basename "$0") --warn 75 --crit 85
    $(basename "$0") --json
    $(basename "$0") --dry-run
EOF
    exit 0
}

# Parse Arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -w|--warn)
            WARN_THRESHOLD="$2"
            shift 2
            ;;
        -c|--crit)
            CRIT_THRESHOLD="$2"
            shift 2
            ;;
        -i|--inode)
            INODE_WARN_THRESHOLD="$2"
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
            echo "Unknown option: $1" >&2
            usage
            ;;
    esac
done

# Initialize logging if not dry run
init_logging() {
    if [ "$DRY_RUN" = false ]; then
        if [ ! -d "$LOG_DIR" ]; then
            mkdir -p "$LOG_DIR" 2>/dev/null || LOG_FILE="/tmp/disk_monitor.log"
        fi
        touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/disk_monitor.log"
    fi
}

log_message() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    if [ "$DRY_RUN" = false ]; then
        echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    fi

    if [ "$JSON_OUTPUT" = false ]; then
        case "$level" in
            CRITICAL)
                echo -e "${RED}[$timestamp] [CRITICAL]${NC} $message" >&2
                ;;
            WARNING)
                echo -e "${YELLOW}[$timestamp] [WARNING]${NC} $message"
                ;;
            INFO)
                echo -e "${GREEN}[$timestamp] [INFO]${NC} $message"
                ;;
            *)
                echo "[$timestamp] [$level] $message"
                ;;
        esac
    fi
}

get_top_consumers() {
    local mount_point="$1"
    if [ "$JSON_OUTPUT" = false ]; then
        echo -e "${BLUE}--> Top 5 Largest Items on ${mount_point}:${NC}"
        du -ahx "$mount_point" 2>/dev/null | sort -rh | head -n 5 || true
    fi
}

check_disks() {
    init_logging

    local alerts_triggered=0
    local json_records=()

    # Read df output excluding pseudo filesystems
    # Compatible across GNU Linux and macOS df
    local df_cmd="df -Pk"

    while read -r fs blocks used avail pct mount; do
        # Strip % symbol
        local usage_num="${pct%\%}"
        if ! [[ "$usage_num" =~ ^[0-9]+$ ]]; then
            continue
        fi

        local status="OK"
        if [ "$usage_num" -ge "$CRIT_THRESHOLD" ]; then
            status="CRITICAL"
            alerts_triggered=$((alerts_triggered + 1))
            log_message "CRITICAL" "Filesystem $fs mounted on $mount is at ${usage_num}% capacity (Threshold: ${CRIT_THRESHOLD}%)"
            get_top_consumers "$mount"
        elif [ "$usage_num" -ge "$WARN_THRESHOLD" ]; then
            status="WARNING"
            alerts_triggered=$((alerts_triggered + 1))
            log_message "WARNING" "Filesystem $fs mounted on $mount is at ${usage_num}% capacity (Threshold: ${WARN_THRESHOLD}%)"
            get_top_consumers "$mount"
        else
            log_message "INFO" "Filesystem $fs mounted on $mount is at ${usage_num}% capacity (Normal)"
        fi

        if [ "$JSON_OUTPUT" = true ]; then
            json_records+=("{\"filesystem\":\"$fs\",\"mount\":\"$mount\",\"usage_pct\":$usage_num,\"blocks\":\"$blocks\",\"used\":\"$used\",\"avail\":\"$avail\",\"status\":\"$status\"}")
        fi

    done < <($df_cmd | grep -vE '^Filesystem|tmpfs|cdrom|overlay|shm|none|devfs')

    # Inode Check
    local inode_cmd="df -Pi"
    if $inode_cmd >/dev/null 2>&1; then
        while read -r fs inodes iused ifree ipct mount; do
            local i_num="${ipct%\%}"
            if ! [[ "$i_num" =~ ^[0-9]+$ ]]; then
                continue
            fi

            if [ "$i_num" -ge "$INODE_WARN_THRESHOLD" ]; then
                alerts_triggered=$((alerts_triggered + 1))
                log_message "WARNING" "Inode usage on $fs mounted on $mount is at ${i_num}% (Threshold: ${INODE_WARN_THRESHOLD}%)"
            fi
        done < <($inode_cmd | grep -vE '^Filesystem|tmpfs|cdrom|overlay|shm|none|devfs' 2>/dev/null || true)
    fi

    if [ "$JSON_OUTPUT" = true ]; then
        local IFS=","
        echo "{\"timestamp\":\"$(date '+%Y-%m-%dT%H:%M:%SZ')\",\"status\":\"$([ "$alerts_triggered" -eq 0 ] && echo "HEALTHY" || echo "ALERT")\",\"alerts_count\":$alerts_triggered,\"filesystems\":[${json_records[*]}]}"
    else
        echo ""
        if [ "$alerts_triggered" -eq 0 ]; then
            echo -e "${GREEN}✓ All filesystems within safe operating limits.${NC}"
        else
            echo -e "${RED}⚠ $alerts_triggered filesystem alert(s) detected! Logged to $LOG_FILE${NC}"
        fi
    fi

    return "$([ "$alerts_triggered" -gt 0 ] && echo 1 || echo 0)"
}

check_disks
