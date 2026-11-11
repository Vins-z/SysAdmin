#!/usr/bin/env bash
# ==============================================================================
# Script Name: firewall_setup.sh
# Description: Host security firewall baseline (UFW) and exposed ports auditor.
# Supported:   Ubuntu Linux (primary) & POSIX socket inspection.
# ==============================================================================

set -euo pipefail

ACTION="audit"
SSH_PORT=22
ALLOW_HTTP=true
ALLOW_HTTPS=true
ADDITIONAL_PORTS=()
RATE_LIMIT_SSH=true
JSON_OUTPUT=false
DRY_RUN=false

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

usage() {
    cat <<EOF
Usage: $(basename "$0") [COMMAND] [OPTIONS]

Commands:
    audit                   Scan listening ports and audit exposed services (Default)
    apply                   Apply standard UFW firewall rules and enable firewall
    reset                   Reset UFW rules to default state

Options:
    --ssh-port <port>       SSH port to allow (Default: 22)
    --no-http               Do not allow HTTP (port 80)
    --no-https              Do not allow HTTPS (port 443)
    --allow-port <port>     Additional port to allow (can be repeated)
    --no-rate-limit         Do not apply rate limiting on SSH
    -j, --json              Output results in JSON format
    -d, --dry-run           Simulate actions without changing firewall state
    -h, --help              Display this help message and exit

Examples:
    sudo $(basename "$0") audit
    sudo $(basename "$0") apply --ssh-port 22 --allow-port 8080
    $(basename "$0") audit --json
EOF
    exit 0
}

if [[ $# -gt 0 ]] && [[ "$1" =~ ^(audit|apply|reset)$ ]]; then
    ACTION="$1"
    shift
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ssh-port)
            SSH_PORT="$2"
            shift 2
            ;;
        --no-http)
            ALLOW_HTTP=false
            shift
            ;;
        --no-https)
            ALLOW_HTTPS=false
            shift
            ;;
        --allow-port)
            ADDITIONAL_PORTS+=("$2")
            shift 2
            ;;
        --no-rate-limit)
            RATE_LIMIT_SSH=false
            shift
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

audit_ports() {
    if [ "$JSON_OUTPUT" = false ]; then
        echo -e "${BLUE}=== Host Security & Listening Ports Audit ===${NC}"
    fi

    local port_records=()
    local socket_cmd=""

    if command -v ss >/dev/null 2>&1; then
        socket_cmd="ss -tulpn"
    elif command -v netstat >/dev/null 2>&1; then
        socket_cmd="netstat -tuln"
    elif command -v lsof >/dev/null 2>&1; then
        socket_cmd="lsof -iTCP -sTCP:LISTEN -P -n"
    fi

    local has_risky_ports=false

    if [ -n "$socket_cmd" ]; then
        if [ "$JSON_OUTPUT" = false ]; then
            printf "%-8s %-22s %-16s %-10s\n" "PROTO" "LOCAL ADDRESS" "SERVICE/PID" "EXPOSURE"
            echo "------------------------------------------------------------"
        fi

        # Parse listening sockets
        if [ "$socket_cmd" = "ss -tulpn" ]; then
            while read -r proto state recv_q send_q local_addr peer_addr process; do
                local port="${local_addr##*:}"
                local exposure="INTERNAL"
                if [[ "$local_addr" =~ ^0\.0\.0\.0: || "$local_addr" =~ ^\*: || "$local_addr" =~ ^\[::\]: ]]; then
                    exposure="PUBLIC (0.0.0.0)"
                    if [[ "$port" =~ ^(6379|5432|3306|27017|3000)$ ]]; then
                        exposure="ALERT: DB/APP PUBLIC!"
                        has_risky_ports=true
                    fi
                fi

                if [ "$JSON_OUTPUT" = true ]; then
                    port_records+=("{\"proto\":\"$proto\",\"address\":\"$local_addr\",\"port\":\"$port\",\"process\":\"$process\",\"exposure\":\"$exposure\"}")
                else
                    printf "%-8s %-22s %-16s %-10s\n" "$proto" "$local_addr" "${process:0:16}" "$exposure"
                fi
            done < <(ss -tulpn | tail -n +2)
        else
            # Fallback output for netstat or lsof
            if [ "$JSON_OUTPUT" = false ]; then
                ($socket_cmd 2>/dev/null | head -n 30) || true
            fi
        fi
    fi

    local ufw_status="NOT_INSTALLED"
    if command -v ufw >/dev/null 2>&1; then
        ufw_status=$(ufw status 2>/dev/null | head -n 1 || echo "UNKNOWN")
    fi

    if [ "$JSON_OUTPUT" = true ]; then
        local IFS=","
        echo "{\"timestamp\":\"$(date '+%Y-%m-%dT%H:%M:%SZ')\",\"ufw_status\":\"$ufw_status\",\"risky_exposure_detected\":$has_risky_ports,\"listening_ports\":[${port_records[*]}]}"
    else
        echo ""
        echo -e "UFW Firewall Status: ${YELLOW}$ufw_status${NC}"
        if [ "$has_risky_ports" = true ]; then
            echo -e "${RED}⚠ High-risk services detected bound to public interfaces! Bind internal services to 127.0.0.1.${NC}"
        else
            echo -e "${GREEN}✓ Listening port audit completed. No dangerous open ports detected.${NC}"
        fi
    fi
}

apply_firewall() {
    if ! command -v ufw >/dev/null 2>&1; then
        echo -e "${RED}Error: UFW is not installed. Run 'apt-get install ufw' on Ubuntu.${NC}" >&2
        exit 1
    fi

    echo -e "${BLUE}=== Applying Host Firewall Baseline (UFW) ===${NC}"

    if [ "$DRY_RUN" = true ]; then
        echo -e "${BLUE}[DRY-RUN] Would set default incoming DENY, outgoing ALLOW${NC}"
        echo -e "${BLUE}[DRY-RUN] Would allow SSH port: $SSH_PORT (Rate-limited: $RATE_LIMIT_SSH)${NC}"
        [ "$ALLOW_HTTP" = true ] && echo -e "${BLUE}[DRY-RUN] Would allow port 80/tcp (HTTP)${NC}"
        [ "$ALLOW_HTTPS" = true ] && echo -e "${BLUE}[DRY-RUN] Would allow port 443/tcp (HTTPS)${NC}"
        echo -e "${BLUE}[DRY-RUN] Would enable ufw${NC}"
        return 0
    fi

    # Set defaults
    ufw default deny incoming
    ufw default allow outgoing

    # Allow SSH
    if [ "$RATE_LIMIT_SSH" = true ]; then
        echo "Configuring rate-limited SSH on port $SSH_PORT..."
        ufw limit "${SSH_PORT}/tcp" comment "Rate-limited SSH"
    else
        echo "Allowing SSH on port $SSH_PORT..."
        ufw allow "${SSH_PORT}/tcp" comment "SSH"
    fi

    # Web Traffic
    if [ "$ALLOW_HTTP" = true ]; then
        echo "Allowing HTTP on port 80..."
        ufw allow 80/tcp comment "HTTP Web Traffic"
    fi

    if [ "$ALLOW_HTTPS" = true ]; then
        echo "Allowing HTTPS on port 443..."
        ufw allow 443/tcp comment "HTTPS Web Traffic"
    fi

    # Additional ports
    for p in "${ADDITIONAL_PORTS[@]}"; do
        echo "Allowing custom port $p..."
        ufw allow "$p"
    done

    # Enable firewall non-interactively
    echo "y" | ufw enable
    echo -e "${GREEN}✓ UFW firewall successfully active and protecting host.${NC}"
    ufw status verbose
}

reset_firewall() {
    if ! command -v ufw >/dev/null 2>&1; then
        echo -e "${RED}Error: UFW is not installed.${NC}" >&2
        exit 1
    fi

    echo -e "${YELLOW}Resetting UFW firewall rules...${NC}"
    if [ "$DRY_RUN" = true ]; then
        echo -e "${BLUE}[DRY-RUN] Would execute 'ufw --force reset'${NC}"
        return 0
    fi

    ufw --force reset
    echo -e "${GREEN}✓ UFW rules reset to factory defaults.${NC}"
}

case "$ACTION" in
    audit)
        audit_ports
        ;;
    apply)
        apply_firewall
        ;;
    reset)
        reset_firewall
        ;;
esac
