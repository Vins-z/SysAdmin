#!/usr/bin/env bash
# ==============================================================================
# Script Name: log_collector.sh
# Description: Centralized log collector, security error parser & archiver.
# Supported:   Ubuntu Linux & standard POSIX log paths.
# ==============================================================================

set -euo pipefail

ARCHIVE_DIR="${ARCHIVE_DIR:-/var/log/serveradmin/archives}"
REPORT_DIR="${REPORT_DIR:-/var/log/serveradmin/reports}"
RETENTION_DAYS=14
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
TEMP_WORK_DIR=""
DRY_RUN=false
JSON_OUTPUT=false

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

cleanup() {
    if [ -n "$TEMP_WORK_DIR" ] && [ -d "$TEMP_WORK_DIR" ]; then
        rm -rf "$TEMP_WORK_DIR"
    fi
}
trap cleanup EXIT

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
    -a, --archive-dir <path>   Destination directory for archives (Default: /var/log/serveradmin/archives)
    -r, --retention <days>     Days to retain archived log packages (Default: 14)
    -j, --json                 Output analysis summary in JSON format
    -d, --dry-run              Inspect and analyze logs without creating permanent archive
    -h, --help                 Display this help message and exit

Examples:
    $(basename "$0") --archive-dir /backups/logs
    $(basename "$0") --json
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -a|--archive-dir)
            ARCHIVE_DIR="$2"
            shift 2
            ;;
        -r|--retention)
            RETENTION_DAYS="$2"
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

init_dirs() {
    if [ "$DRY_RUN" = false ]; then
        mkdir -p "$ARCHIVE_DIR" 2>/dev/null || ARCHIVE_DIR="/tmp/serveradmin/archives"
        mkdir -p "$REPORT_DIR" 2>/dev/null || REPORT_DIR="/tmp/serveradmin/reports"
        mkdir -p "$ARCHIVE_DIR" "$REPORT_DIR" 2>/dev/null || true
    fi
    TEMP_WORK_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t 'logcoll')
}

collect_and_analyze() {
    init_dirs
    local bundle_dir="${TEMP_WORK_DIR}/logs_${TIMESTAMP}"
    mkdir -p "$bundle_dir"

    # 1. Collect standard log files if available
    local files_collected=0
    for log_path in /var/log/syslog /var/log/messages /var/log/auth.log /var/log/secure /var/log/nginx /var/log/docker; do
        if [ -f "$log_path" ] && [ -r "$log_path" ]; then
            cp -r "$log_path" "$bundle_dir/" 2>/dev/null && files_collected=$((files_collected + 1)) || true
        elif [ -d "$log_path" ] && [ -r "$log_path" ]; then
            cp -r "$log_path" "$bundle_dir/" 2>/dev/null && files_collected=$((files_collected + 1)) || true
        fi
    done

    # 2. Extract journalctl if available
    if command -v journalctl >/dev/null 2>&1; then
        journalctl --since "24 hours ago" -p err..emerg --no-pager > "${bundle_dir}/journalctl_errors_24h.log" 2>/dev/null || true
    fi

    # 3. Security Analysis: Parse failed logins and threats
    local failed_logins=0
    local top_bad_ips=""
    local auth_log_source=""

    if [ -f "${bundle_dir}/auth.log" ]; then
        auth_log_source="${bundle_dir}/auth.log"
    elif [ -f "${bundle_dir}/secure" ]; then
        auth_log_source="${bundle_dir}/secure"
    fi

    if [ -n "$auth_log_source" ]; then
        failed_logins=$(grep -iE "Failed password|Invalid user|authentication failure" "$auth_log_source" 2>/dev/null | wc -l || echo 0)
        top_bad_ips=$(grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b" "$auth_log_source" 2>/dev/null | sort | uniq -c | sort -nr | head -n 5 || echo "None")
    fi

    # 4. Create archive bundle
    local archive_file="${ARCHIVE_DIR}/logs_${TIMESTAMP}.tar.gz"
    local report_file="${REPORT_DIR}/audit_summary_${TIMESTAMP}.txt"

    if [ "$DRY_RUN" = false ]; then
        tar -czf "$archive_file" -C "$TEMP_WORK_DIR" "logs_${TIMESTAMP}" 2>/dev/null || true

        # Write analytical report
        cat <<EOF > "$report_file"
==================================================
  SERVERADMIN LOG COLLECTION & AUDIT REPORT
==================================================
Timestamp:       $(date '+%Y-%m-%d %H:%M:%S')
Archive File:    $archive_file
Files Collected: $files_collected
Failed Auth Attempts (24h): $failed_logins

Top Attacking / Suspicious IPs:
${top_bad_ips:-None detected}
==================================================
EOF

        # 5. Prune old archives
        find "$ARCHIVE_DIR" -type f -name "logs_*.tar.gz" -mtime +"$RETENTION_DAYS" -exec rm -f {} + 2>/dev/null || true
    fi

    # Output representation
    if [ "$JSON_OUTPUT" = true ]; then
        echo "{\"timestamp\":\"$TIMESTAMP\",\"archive_file\":\"$archive_file\",\"report_file\":\"$report_file\",\"files_collected\":$files_collected,\"failed_logins\":$failed_logins,\"retention_days\":$RETENTION_DAYS,\"dry_run\":$DRY_RUN}"
    else
        echo -e "${BLUE}=== Log Collection & Security Analysis ===${NC}"
        echo -e "Files Collected: ${GREEN}$files_collected${NC}"
        echo -e "Failed Logins:   ${RED}$failed_logins${NC}"
        if [ "$DRY_RUN" = false ]; then
            echo -e "Archive Created: ${GREEN}$archive_file${NC}"
            echo -e "Report Saved:    ${GREEN}$report_file${NC}"
        else
            echo -e "Mode:            ${YELLOW}DRY-RUN (No archive written)${NC}"
        fi
        echo -e "${GREEN}✓ Log aggregation cycle completed successfully.${NC}"
    fi
}

collect_and_analyze

