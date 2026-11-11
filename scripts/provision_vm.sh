#!/usr/bin/env bash
# ==============================================================================
# Script Name: provision_vm.sh
# Description: Automated Ubuntu VM initial bootstrapper, package installer,
#              Docker/Compose & Nginx provisioner, and cron scheduler.
# Supported:   Ubuntu 20.04 / 22.04 / 24.04 LTS (AWS, GCP, DO, Multipass, etc.)
# ==============================================================================

set -euo pipefail

ADMIN_USER="${ADMIN_USER:-adminuser}"
INSTALL_DOCKER=true
INSTALL_NGINX=true
HARDEN_SSH=true
SETUP_CRON=true
DRY_RUN=false

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

if [ "$(id -u)" -ne 0 ] && [ "$DRY_RUN" = false ]; then
    echo -e "${RED}Error: provision_vm.sh must be run as root or with sudo.${NC}" >&2
    exit 1
fi

echo -e "${BLUE}====================================================${NC}"
echo -e "${BLUE}  Ubuntu Server Administration Automation Engine    ${NC}"
echo -e "${BLUE}  Initial Server Provisioning & Environment Setup   ${NC}"
echo -e "${BLUE}====================================================${NC}"

# 1. System Package Updates & Prerequisites
echo -e "\n${YELLOW}[1/6] Updating system packages...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get install -y --no-install-recommends \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    software-properties-common \
    htop \
    iotop \
    net-tools \
    iproute2 \
    ufw \
    fail2ban \
    jq \
    tar \
    gzip \
    rsync \
    git

# 2. Install Docker & Docker Compose
if [ "$INSTALL_DOCKER" = true ]; then
    echo -e "\n${YELLOW}[2/6] Installing Docker Engine & Docker Compose...${NC}"
    if ! command -v docker >/dev/null 2>&1; then
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
        chmod a+r /etc/apt/keyrings/docker.gpg

        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
          $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
          tee /etc/apt/sources.list.d/docker.list > /dev/null

        apt-get update -y
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        systemctl enable --now docker
        echo -e "${GREEN}✓ Docker Engine successfully installed and started.${NC}"
    else
        echo -e "${GREEN}✓ Docker already installed.${NC}"
    fi
fi

# 3. Install Nginx Reverse Proxy
if [ "$INSTALL_NGINX" = true ]; then
    echo -e "\n${YELLOW}[3/6] Installing Nginx Web Server / Reverse Proxy...${NC}"
    if ! command -v nginx >/dev/null 2>&1; then
        apt-get install -y nginx
        systemctl enable nginx
        systemctl start nginx || true
        echo -e "${GREEN}✓ Nginx installed and enabled.${NC}"
    else
        echo -e "${GREEN}✓ Nginx already installed.${NC}"
    fi
fi

# 4. SSH Host Hardening
if [ "$HARDEN_SSH" = true ]; then
    echo -e "\n${YELLOW}[4/6] Hardening SSH Configuration...${NC}"
    SSH_HARDEN_CONF="/etc/ssh/sshd_config.d/99-hardened.conf"
    mkdir -p /etc/ssh/sshd_config.d
    cat <<EOF > "$SSH_HARDEN_CONF"
# ServerAdmin Hardened SSH Baseline
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
MaxAuthTries 4
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
EOF
    # Validate and reload ssh
    if sshd -t 2>/dev/null; then
        systemctl reload ssh || systemctl reload sshd || true
        echo -e "${GREEN}✓ SSH configuration hardened.${NC}"
    else
        echo -e "${RED}⚠ SSH test failed. Reverting 99-hardened.conf${NC}"
        rm -f "$SSH_HARDEN_CONF"
    fi
fi

# 5. Initialize ServerAdmin File System Hierarchy
echo -e "\n${YELLOW}[5/6] Initializing ServerAdmin directory structure...${NC}"
mkdir -p /var/log/serveradmin/archives
mkdir -p /var/log/serveradmin/reports
mkdir -p /var/backups/serveradmin
mkdir -p /opt/serveradmin/scripts
chmod 750 /var/log/serveradmin
chmod 700 /var/backups/serveradmin

# 6. Configure Automated Cron Maintenance Jobs
if [ "$SETUP_CRON" = true ]; then
    echo -e "\n${YELLOW}[6/6] Installing automated cron jobs...${NC}"
    CRON_FILE="/etc/cron.d/serveradmin-automation"
    cat <<EOF > "$CRON_FILE"
# /etc/cron.d/serveradmin-automation
# Automated Server Maintenance & Monitoring Jobs

SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# 1. Hourly Service Health Watchdog
*/30 * * * * root /opt/serveradmin/scripts/service_health.sh >> /var/log/serveradmin/service_health.log 2>&1

# 2. Hourly Disk Usage and Inode Check
0 * * * * root /opt/serveradmin/scripts/disk_monitor.sh --warn 80 --crit 90 >> /var/log/serveradmin/disk_monitor.log 2>&1

# 3. Daily Log Aggregation & Rotation at 01:00
0 1 * * * root /opt/serveradmin/scripts/log_collector.sh >> /var/log/serveradmin/log_collector.log 2>&1

# 4. Daily Verified Timestamped Backup at 02:00
0 2 * * * root /opt/serveradmin/scripts/backup_engine.sh --retention 7 >> /var/log/serveradmin/backup.log 2>&1
EOF
    chmod 0644 "$CRON_FILE"
    echo -e "${GREEN}✓ Cron automation scheduled in $CRON_FILE${NC}"
fi

echo -e "\n${GREEN}====================================================${NC}"
echo -e "${GREEN}  Server Provisioning & Baseline Setup Complete!   ${NC}"
echo -e "${GREEN}====================================================${NC}"

