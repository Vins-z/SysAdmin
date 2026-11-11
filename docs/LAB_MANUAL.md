# Linux Server Administration & Deployment Automation Lab Manual

A complete, hands-on operational lab guide covering Ubuntu server provisioning, SSH access, core Linux administration, production Bash scripting, containerized application deployment with Docker & Compose, Nginx reverse proxy configuration, and host security hardening.

---

## Lab Architecture & Prerequisites

### Minimum Requirements
- **Target OS**: Ubuntu 22.04 LTS or Ubuntu 24.04 LTS (Local VM via Multipass/VirtualBox/UTM, or Cloud VM on AWS EC2, GCP, DigitalOcean, Hetzner).
- **RAM**: 1 GB minimum (2 GB recommended).
- **Disk**: 15 GB minimum storage.
- **Admin Workstation**: Linux, macOS, or Windows WSL2 with OpenSSH client.

---

## Lab 1: Ubuntu Server Provisioning & SSH Access

### 1.1 Provisioning the Ubuntu Virtual Machine

#### Option A: Local Multipass (Fastest local setup)
```bash
# Install multipass (if not already installed)
# macOS: brew install multipass | Ubuntu: sudo snap install multipass

# Launch an Ubuntu 22.04 LTS instance
multipass launch 22.04 --name ubuntu-lab --cpus 2 --memory 2G --disk 15G

# Obtain instance IP
multipass info ubuntu-lab
```

#### Option B: Cloud Provider (AWS EC2 / DigitalOcean)
- Launch an `Ubuntu 22.04 LTS` `t3.micro` or `t2.small` instance.
- In security groups, initially open:
  - Inbound: Port 22 (SSH) from your IP.
  - Inbound: Port 80 (HTTP) and Port 443 (HTTPS) from any (0.0.0.0/0).

### 1.2 SSH Key Pair Generation & Setup

On your local admin workstation:
```bash
# Generate a modern Ed25519 keypair
ssh-keygen -t ed25519 -C "admin@serveradmin-lab" -f ~/.ssh/id_ed25519_lab

# Copy public key to the remote server
ssh-copy-id -i ~/.ssh/id_ed25519_lab.pub ubuntu@<SERVER_IP>

# Verify connection
ssh -i ~/.ssh/id_ed25519_lab ubuntu@<SERVER_IP>
```

### 1.3 Automated Server Provisioning
Once connected to the server, clone this repository and run the automated provisioning engine:
```bash
git clone https://github.com/your-org/serverAdmin.git
cd serverAdmin
sudo ./scripts/provision_vm.sh
```
This automatically updates system packages, installs Docker Engine, Docker Compose, Nginx, hardens SSH, creates required directories, and schedules maintenance cron jobs.

---

## Lab 2: Core Linux Administration Operations

### 2.1 User and Group Administration
Create dedicated service accounts adhering to least privilege:

```bash
# Provision a deployer user with Docker group and passwordless sudo
sudo ./scripts/setup_users.sh \
  -u deploy \
  -G docker \
  --sudo \
  --nopasswd \
  -K ~/.ssh/id_ed25519_lab.pub

# Provision a read-only auditor user without sudo
sudo ./scripts/setup_users.sh \
  -u auditor \
  -s /bin/bash \
  -K ~/.ssh/id_ed25519_lab.pub
```

Verify user entries:
```bash
getent passwd deploy
groups deploy
cat /etc/sudoers.d/90-deploy
```

### 2.2 File Permissions & Directory Security
Enforce POSIX permission boundaries:
```bash
# Sensitive configurations: Read/Write by owner only
sudo chmod 0600 /etc/ssh/sshd_config.d/*
sudo chmod 0440 /etc/sudoers.d/*

# Backup and log storage permissions
sudo chmod 750 /var/log/serveradmin
sudo chmod 700 /var/backups/serveradmin
```

### 2.3 Process Inspection & Service Control
Monitor system resources and control systemd daemons:
```bash
# Inspect top memory and CPU consuming processes
ps aux --sort=-%cpu | head -n 10
ps aux --sort=-%mem | head -n 10

# Real-time resource inspection
htop

# Service lifecycle control
sudo systemctl status nginx
sudo systemctl restart nginx
sudo systemctl is-active docker
```

---

## Lab 3: Automation Scripts for Routine Maintenance

This platform ships with four production-hardened Bash administration scripts located in `scripts/`:

### 3.1 Disk & Inode Capacity Monitor (`scripts/disk_monitor.sh`)
- Monitors filesystem thresholds (default 80% warning, 90% critical).
- Checks inode exhaustion.
- Recursively inspects and lists top 5 largest files on high-capacity mounts.
- Writes structured entries to `/var/log/serveradmin/disk_monitor.log`.

```bash
# Run threshold check
./scripts/disk_monitor.sh --warn 75 --crit 85

# JSON machine-readable output
./scripts/disk_monitor.sh --json
```

### 3.2 Systemd Service Health Watchdog (`scripts/service_health.sh`)
- Monitors critical daemons (`nginx`, `docker`, `ssh`, `cron`).
- Employs self-healing: automatically restarts failed services with exponential backoff.
- Logs events to `/var/log/serveradmin/service_health.log` and syslog.

```bash
# Run health inspection
./scripts/service_health.sh

# Monitor specific custom services
./scripts/service_health.sh -s "nginx docker redis"
```

### 3.3 Centralized Log Collection & Parser (`scripts/log_collector.sh`)
- Aggregates `/var/log/syslog`, `/var/log/auth.log`, and `journalctl`.
- Analyzes failed SSH attempts, brute force scans, and malicious IP patterns.
- Bundles logs into a timestamped, compressed package: `/var/log/serveradmin/archives/logs_YYYYMMDD_HHMMSS.tar.gz`.
- Automatically prunes archives older than 14 days.

```bash
./scripts/log_collector.sh
```

### 3.4 Timestamped & SHA-256 Verified Backup Engine (`scripts/backup_engine.sh`)
- Backs up configuration (`/etc/nginx`), application code, and data.
- Produces timestamped gzip archives: `backup_YYYYMMDD_HHMMSS.tar.gz`.
- Computes SHA-256 integrity hash (`.sha256`).
- Automatic retention policy (prunes archives older than 7 days).
- Built-in verification and restore engine.

```bash
# Run backup
./scripts/backup_engine.sh --dest /var/backups/serveradmin --target /etc/nginx --target ./app_stack

# Verify integrity and checksum of latest backup
./scripts/backup_engine.sh --dest /var/backups/serveradmin --verify-latest

# Restore an archive
./scripts/backup_engine.sh --restore /var/backups/serveradmin/backup_YYYYMMDD_HHMMSS.tar.gz --restore-to /tmp/restored_config
```

### 3.5 Automated Scheduling via Cron
The script `scripts/provision_vm.sh` installs `/etc/cron.d/serveradmin-automation`:
```cron
# Service Health Watchdog every 30 minutes
*/30 * * * * root /opt/serveradmin/scripts/service_health.sh >> /var/log/serveradmin/service_health.log 2>&1

# Disk Usage & Inode checks every hour
0 * * * * root /opt/serveradmin/scripts/disk_monitor.sh --warn 80 --crit 90 >> /var/log/serveradmin/disk_monitor.log 2>&1

# Centralized Log Aggregation daily at 01:00
0 1 * * * root /opt/serveradmin/scripts/log_collector.sh >> /var/log/serveradmin/log_collector.log 2>&1

# Daily Verified Backup at 02:00
0 2 * * * root /opt/serveradmin/scripts/backup_engine.sh --retention 7 >> /var/log/serveradmin/backup.log 2>&1
```

---

## Lab 4: Containerized Web App & Nginx Reverse Proxy

### 4.1 Architecture & Network Isolation
The application stack is defined in `app_stack/docker-compose.yml`:
1. **Nginx Reverse Proxy** (`serveradmin_nginx`):
   - Ingress on port `80` (HTTP) and `443` (HTTPS).
   - Injected security headers (`X-Frame-Options`, `X-Content-Type-Options`, `X-XSS-Protection`).
   - Rate limiting: 10 req/sec with burst buffer of 20 requests.
   - Forwards traffic to `web_app:3000` over `frontend_net`.
2. **Node.js Web App** (`serveradmin_webapp`):
   - Runs as non-root user (`node`).
   - Connected to `frontend_net` and `backend_net`.
   - Never exposes its port directly to the host!
3. **Redis Cache** (`serveradmin_cache`):
   - Isolated in `backend_net`.
   - Password-protected via `REDIS_PASSWORD`.
   - Persistent Docker volume `cache_data`.

### 4.2 Configuration Management (.env)
Edit `app_stack/.env`:
```ini
APP_ENV=production
APP_NAME="Production DevOps Portal"
HOST_PORT_HTTP=80
HOST_PORT_HTTPS=443
ENABLE_REDIS=true
REDIS_PASSWORD="generate_a_secure_token_here"
```

### 4.3 Deployment & Verification
```bash
cd app_stack

# Build and launch multi-container stack in background
docker compose up -d --build

# Verify container health
docker compose ps

# Test reverse proxy endpoint
curl -I http://localhost/
curl -I http://localhost/healthz

# Verify rate limiting by sending 25 rapid requests
for i in {1..25}; do curl -s -o /dev/null -w "%{http_code}\n" http://localhost/; done
```

---

## Lab 5: Host Security Hardening & Port Exposure Audit

### 5.1 SSH Hardening Baseline
Verify that password authentication and direct root login are disabled in `/etc/ssh/sshd_config.d/99-hardened.conf`:
```ini
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
MaxAuthTries 4
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
```

### 5.2 UFW Firewall Configuration
Apply default deny policy and permit only essential services:
```bash
sudo ./scripts/firewall_setup.sh apply --ssh-port 22
```
This enforces:
- Inbound: `DENY` by default
- Outbound: `ALLOW` by default
- Port 22/tcp: `LIMIT` (Rate-limited to prevent brute force)
- Port 80/tcp: `ALLOW` (HTTP)
- Port 443/tcp: `ALLOW` (HTTPS)

### 5.3 Listening Sockets & Port Exposure Audit
Inspect listening sockets to verify that database or internal application ports are NOT exposed to public interfaces:
```bash
sudo ./scripts/firewall_setup.sh audit
```
The audit checks all listening sockets (`ss -tulpn`):
- Port `80`, `443`: Public Ingress (`0.0.0.0`) -> Allowed (Reverse Proxy)
- Port `22`: SSH -> Allowed & Rate-limited
- Port `6379`, `3000`: Internal Only (Docker bridge networks / `127.0.0.1`) -> Protected!

---

## Summary of Operations & CLI Usage

You can control all labs centrally via the `serveradmin` CLI or the Web Management Console:

```bash
# Global system health and services
./bin/serveradmin status

# Run security and listening ports audit
./bin/serveradmin security audit

# Trigger verified backup
./bin/serveradmin backup run

# Verify latest backup
./bin/serveradmin backup verify

# Run web management control plane
node web_platform/server.js
# Access dashboard at http://localhost:8080
```

