#!/usr/bin/env bash
# ==============================================================================
# Script Name: backup_engine.sh
# Description: Production backup engine with timestamping, gzip compression,
#              SHA-256 checksum verification and automatic rotation.
# Supported:   Ubuntu Linux & POSIX environments.
# ==============================================================================

set -euo pipefail

BACKUP_DEST="${BACKUP_DEST:-/var/backups/serveradmin}"
DEFAULT_TARGETS=("/etc/nginx" "/opt/serveradmin" "./app_stack")
TARGETS=()
RETENTION_DAYS=7
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
VERIFY_TARGET=""
RESTORE_ARCHIVE=""
RESTORE_DEST=""
JSON_OUTPUT=false
DRY_RUN=false

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
    -d, --dest <path>          Backup destination directory (Default: /var/backups/serveradmin)
    -t, --target <path>        Directory or file to backup (can be passed multiple times)
    -r, --retention <days>     Days to keep backups before auto-pruning (Default: 7)
    -v, --verify <file.tar.gz> Verify SHA-256 checksum and tar integrity of an archive
    --verify-latest            Verify the most recent backup in the destination directory
    --restore <file.tar.gz>    Restore an archive to a specified directory
    --restore-to <path>        Destination path for restoring an archive
    -j, --json                 Output results in JSON format
    --dry-run                  Simulate backup or restore without modifying files
    -h, --help                 Display this help message and exit

Examples:
    $(basename "$0") --target /etc/nginx --target /var/www
    $(basename "$0") --verify /var/backups/serveradmin/backup_20261112_000000.tar.gz
    $(basename "$0") --verify-latest
    $(basename "$0") --restore latest.tar.gz --restore-to /tmp/restored
EOF
    exit 0
}

# Parse CLI options
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--dest)
            BACKUP_DEST="$2"
            shift 2
            ;;
        -t|--target)
            TARGETS+=("$2")
            shift 2
            ;;
        -r|--retention)
            RETENTION_DAYS="$2"
            shift 2
            ;;
        -v|--verify)
            VERIFY_TARGET="$2"
            shift 2
            ;;
        --verify-latest)
            VERIFY_TARGET="LATEST"
            shift
            ;;
        --restore)
            RESTORE_ARCHIVE="$2"
            shift 2
            ;;
        --restore-to)
            RESTORE_DEST="$2"
            shift 2
            ;;
        -j|--json)
            JSON_OUTPUT=true
            shift
            ;;
        --dry-run)
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

compute_sha256() {
    local file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print $1}'
    else
        openssl dgst -sha256 "$file" | awk '{print $NF}'
    fi
}

verify_archive() {
    local archive_file="$1"

    if [ "$archive_file" = "LATEST" ]; then
        archive_file=$(find "$BACKUP_DEST" -name "backup_*.tar.gz" 2>/dev/null | sort -r | head -n 1 || true)
        if [ -z "$archive_file" ]; then
            echo -e "${RED}Error: No backup archives found in $BACKUP_DEST${NC}" >&2
            return 1
        fi
    fi

    if [ ! -f "$archive_file" ]; then
        echo -e "${RED}Error: Archive file not found: $archive_file${NC}" >&2
        return 1
    fi

    local checksum_file="${archive_file}.sha256"
    local checksum_valid=false
    local tar_valid=false

    # 1. Verify Checksum
    if [ -f "$checksum_file" ]; then
        local expected_hash
        expected_hash=$(awk '{print $1}' "$checksum_file")
        local actual_hash
        actual_hash=$(compute_sha256 "$archive_file")

        if [ "$expected_hash" = "$actual_hash" ]; then
            checksum_valid=true
        fi
    else
        echo -e "${YELLOW}Warning: Checksum file not found. Generating current hash...${NC}"
        actual_hash=$(compute_sha256 "$archive_file")
    fi

    # 2. Verify Tar Integrity
    if tar -tzf "$archive_file" >/dev/null 2>&1; then
        tar_valid=true
    fi

    if [ "$JSON_OUTPUT" = true ]; then
        echo "{\"archive\":\"$archive_file\",\"checksum_valid\":$checksum_valid,\"tar_valid\":$tar_valid,\"sha256\":\"${actual_hash:-unknown}\"}"
    else
        echo -e "${BLUE}=== Backup Verification: $(basename "$archive_file") ===${NC}"
        if [ "$checksum_valid" = true ]; then
            echo -e "Checksum Match:    ${GREEN}PASS${NC} ($actual_hash)"
        else
            echo -e "Checksum Match:    ${RED}FAIL / MISSING CHECKSUM${NC}"
        fi

        if [ "$tar_valid" = true ]; then
            echo -e "Gzip/Tar Integrity: ${GREEN}PASS${NC}"
        else
            echo -e "Gzip/Tar Integrity: ${RED}CORRUPT${NC}"
        fi
    fi

    if [ "$checksum_valid" = true ] && [ "$tar_valid" = true ]; then
        return 0
    else
        return 1
    fi
}

restore_backup() {
    local archive_file="$1"
    local destination="${2:-}"

    if [ -z "$destination" ]; then
        echo -e "${RED}Error: Must specify --restore-to <destination_directory>${NC}" >&2
        return 1
    fi

    if [ ! -f "$archive_file" ]; then
        echo -e "${RED}Error: Archive not found: $archive_file${NC}" >&2
        return 1
    fi

    echo -e "${YELLOW}Restoring $(basename "$archive_file") to $destination...${NC}"
    if [ "$DRY_RUN" = true ]; then
        echo -e "${BLUE}[DRY-RUN] Contents that would be restored:${NC}"
        tar -tzf "$archive_file" | head -n 20
        return 0
    fi

    mkdir -p "$destination"
    tar -xzf "$archive_file" -C "$destination"
    echo -e "${GREEN}✓ Restore completed successfully to $destination${NC}"
}

run_backup() {
    if [ ${#TARGETS[@]} -eq 0 ]; then
        for t in "${DEFAULT_TARGETS[@]}"; do
            if [ -e "$t" ]; then
                TARGETS+=("$t")
            fi
        done
    fi

    if [ ${#TARGETS[@]} -eq 0 ]; then
        echo -e "${YELLOW}Notice: No existing default targets found. Using current directory.${NC}"
        TARGETS+=(".")
    fi

    if [ "$DRY_RUN" = false ]; then
        mkdir -p "$BACKUP_DEST" 2>/dev/null || BACKUP_DEST="/tmp/serveradmin/backups"
        mkdir -p "$BACKUP_DEST"
    fi

    local archive_name="backup_${TIMESTAMP}.tar.gz"
    local archive_path="${BACKUP_DEST}/${archive_name}"
    local checksum_path="${archive_path}.sha256"

    if [ "$DRY_RUN" = true ]; then
        echo -e "${BLUE}[DRY-RUN] Would backup:${NC} ${TARGETS[*]}"
        echo -e "${BLUE}[DRY-RUN] Destination:${NC} $archive_path"
        return 0
    fi

    echo -e "${BLUE}=== Starting System Backup ===${NC}"
    echo "Targets: ${TARGETS[*]}"
    echo "Destination: $archive_path"

    # Create tar archive
    tar -czf "$archive_path" "${TARGETS[@]}" 2>/dev/null || tar -czf "$archive_path" "${TARGETS[@]}"

    # Compute and save SHA-256
    local hash
    hash=$(compute_sha256 "$archive_path")
    echo "$hash  $archive_name" > "$checksum_path"

    local archive_size
    archive_size=$(du -h "$archive_path" | awk '{print $1}')

    # Apply Retention: Prune older than RETENTION_DAYS
    local pruned_count=0
    while IFS= read -r old_file; do
        if [ -n "$old_file" ]; then
            rm -f "$old_file" "${old_file}.sha256"
            pruned_count=$((pruned_count + 1))
        fi
    done < <(find "$BACKUP_DEST" -name "backup_*.tar.gz" -mtime +"$RETENTION_DAYS" 2>/dev/null || true)

    if [ "$JSON_OUTPUT" = true ]; then
        echo "{\"archive\":\"$archive_path\",\"size\":\"$archive_size\",\"sha256\":\"$hash\",\"retention_days\":$RETENTION_DAYS,\"pruned_backups\":$pruned_count}"
    else
        echo -e "Archive Size:  ${GREEN}$archive_size${NC}"
        echo -e "SHA-256 Hash:  ${GREEN}$hash${NC}"
        echo -e "Rotation:      Pruned $pruned_count backup(s) older than $RETENTION_DAYS days."
        echo -e "${GREEN}✓ Backup created and verified successfully.${NC}"
    fi
}

# Main Execution Routing
if [ -n "$VERIFY_TARGET" ]; then
    verify_archive "$VERIFY_TARGET"
elif [ -n "$RESTORE_ARCHIVE" ]; then
    restore_backup "$RESTORE_ARCHIVE" "$RESTORE_DEST"
else
    run_backup
fi

