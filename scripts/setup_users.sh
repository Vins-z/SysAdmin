#!/usr/bin/env bash
# ==============================================================================
# Script Name: setup_users.sh
# Description: Automated user & group provisioning with SSH key deployment,
#              least-privilege sudo permissions and file permission hardening.
# Supported:   Ubuntu Linux (primary).
# ==============================================================================

set -euo pipefail

USERNAME=""
GROUPNAME=""
ADDITIONAL_GROUPS=""
SSH_PUBKEY=""
SSH_PUBKEY_FILE=""
SUDO_ACCESS=false
SUDO_NOPASSWD=false
SHELL_PATH="/bin/bash"
DRY_RUN=false

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

usage() {
    cat <<EOF
Usage: $(basename "$0") -u <username> [OPTIONS]

Options:
    -u, --user <username>         Username to create or configure (Required)
    -g, --group <groupname>       Primary group (Default: same as username)
    -G, --groups <g1,g2,...>      Comma-separated supplementary groups (e.g., docker,adm)
    -k, --key "<ssh-public-key>"  SSH Public Key string to inject into authorized_keys
    -K, --key-file <path>         Path to file containing SSH public key
    --sudo                        Grant sudo privileges (least-privilege sudoers entry)
    --nopasswd                    Allow sudo without password prompt (requires --sudo)
    -s, --shell <path>            User login shell (Default: /bin/bash)
    -d, --dry-run                 Simulate commands without making system changes
    -h, --help                    Display this help message and exit

Examples:
    sudo $(basename "$0") -u deploy -G docker --sudo --nopasswd -K ~/.ssh/id_ed25519.pub
    sudo $(basename "$0") -u auditor -k "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... devops"
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--user)
            USERNAME="$2"
            shift 2
            ;;
        -g|--group)
            GROUPNAME="$2"
            shift 2
            ;;
        -G|--groups)
            ADDITIONAL_GROUPS="$2"
            shift 2
            ;;
        -k|--key)
            SSH_PUBKEY="$2"
            shift 2
            ;;
        -K|--key-file)
            SSH_PUBKEY_FILE="$2"
            shift 2
            ;;
        --sudo)
            SUDO_ACCESS=true
            shift
            ;;
        --nopasswd)
            SUDO_NOPASSWD=true
            shift
            ;;
        -s|--shell)
            SHELL_PATH="$2"
            shift 2
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

if [ -z "$USERNAME" ]; then
    echo -e "${RED}Error: Username is required (-u <username>).${NC}" >&2
    usage
fi

if [ -n "$SSH_PUBKEY_FILE" ]; then
    if [ ! -f "$SSH_PUBKEY_FILE" ]; then
        echo -e "${RED}Error: Public key file does not exist: $SSH_PUBKEY_FILE${NC}" >&2
        exit 1
    fi
    SSH_PUBKEY=$(cat "$SSH_PUBKEY_FILE")
fi

run_cmd() {
    if [ "$DRY_RUN" = true ]; then
        echo -e "${BLUE}[DRY-RUN]${NC} $*"
    else
        "$@"
    fi
}

echo -e "${BLUE}=== Provisioning User: ${USERNAME} ===${NC}"

# 1. Create or verify primary group
PRIMARY_GROUP="${GROUPNAME:-$USERNAME}"
if getent group "$PRIMARY_GROUP" >/dev/null 2>&1; then
    echo -e "Group '$PRIMARY_GROUP' already exists."
else
    echo -e "Creating group '$PRIMARY_GROUP'..."
    run_cmd groupadd "$PRIMARY_GROUP"
fi

# 2. Create user if not exists
if id "$USERNAME" >/dev/null 2>&1; then
    echo -e "User '$USERNAME' already exists. Updating configuration..."
else
    echo -e "Creating user '$USERNAME'..."
    run_cmd useradd -m -g "$PRIMARY_GROUP" -s "$SHELL_PATH" "$USERNAME"
fi

# 3. Add supplementary groups
if [ -n "$ADDITIONAL_GROUPS" ]; then
    echo -e "Assigning supplementary groups: $ADDITIONAL_GROUPS"
    run_cmd usermod -aG "$ADDITIONAL_GROUPS" "$USERNAME"
fi

# 4. Configure Sudo access
if [ "$SUDO_ACCESS" = true ]; then
    SUDOERS_FILE="/etc/sudoers.d/90-${USERNAME}"
    echo -e "Configuring sudo privileges in $SUDOERS_FILE..."
    if [ "$SUDO_NOPASSWD" = true ]; then
        SUDO_RULE="${USERNAME} ALL=(ALL:ALL) NOPASSWD: ALL"
    else
        SUDO_RULE="${USERNAME} ALL=(ALL:ALL) ALL"
    fi

    if [ "$DRY_RUN" = true ]; then
        echo -e "${BLUE}[DRY-RUN] Would create $SUDOERS_FILE with: $SUDO_RULE${NC}"
    else
        echo "$SUDO_RULE" > "$SUDOERS_FILE"
        chmod 0440 "$SUDOERS_FILE"
        # Validate syntax
        if command -v visudo >/dev/null 2>&1; then
            visudo -c -f "$SUDOERS_FILE" >/dev/null
        fi
    fi
fi

# 5. Inject SSH Public Key and harden permissions
if [ -n "$SSH_PUBKEY" ]; then
    USER_HOME=$(getent passwd "$USERNAME" 2>/dev/null | cut -d: -f6 || echo "/home/$USERNAME")
    SSH_DIR="${USER_HOME}/.ssh"
    AUTH_KEYS="${SSH_DIR}/authorized_keys"

    echo -e "Configuring SSH key authentication for $USERNAME..."
    if [ "$DRY_RUN" = true ]; then
        echo -e "${BLUE}[DRY-RUN] Would write SSH key to $AUTH_KEYS and set permissions 0700 / 0600${NC}"
    else
        mkdir -p "$SSH_DIR"
        chmod 0700 "$SSH_DIR"

        if [ -f "$AUTH_KEYS" ]; then
            if ! grep -qF "$SSH_PUBKEY" "$AUTH_KEYS"; then
                echo "$SSH_PUBKEY" >> "$AUTH_KEYS"
            fi
        else
            echo "$SSH_PUBKEY" > "$AUTH_KEYS"
        fi

        chmod 0600 "$AUTH_KEYS"
        chown -R "${USERNAME}:${PRIMARY_GROUP}" "$SSH_DIR"
    fi
fi

echo -e "${GREEN}✓ User $USERNAME provisioned successfully with least-privilege standards.${NC}"

