# Host Security Runbook & Incident Response Guide

This runbook defines security controls, monitoring thresholds, auditing routines, and emergency disaster recovery procedures for systems managed by the **ServerAdmin Platform**.

---

## 1. Threat Scenarios & Automated Mitigations

| Threat Vector | Potential Impact | Automated Mitigation | Manual Verification Command |
| :--- | :--- | :--- | :--- |
| **SSH Brute-Force Attacks** | Credential guessing, CPU spikes | Passwords disabled; UFW rate limiting (`ufw limit 22/tcp`); Fail2ban jail monitoring | `grep -i "Failed password" /var/log/auth.log` or `./scripts/log_collector.sh` |
| **Rogue / Accidental Port Exposure** | Unauthenticated DB access (Redis/MySQL/PostgreSQL) | Dual Docker networks; Port auditor scans listening sockets | `./scripts/firewall_setup.sh audit` |
| **Disk Exhaustion (DoS)** | Database corruption, service crashes | Hourly disk & inode monitor alerts at 80% and 90%; automated log rotation | `./scripts/disk_monitor.sh` |
| **Silent Backup Corruption** | Data loss during disaster recovery | SHA-256 integrity checksum verification; gzip tar test | `./scripts/backup_engine.sh --verify-latest` |
| **Unauthorized Privilege Escalation** | Root takeover | Least privilege sudoers (`/etc/sudoers.d/`); non-root container execution (`USER node`) | `getent group sudo; cat /etc/sudoers.d/*` |

---

## 2. Security Auditing Checklist

Run the following commands during routine operational reviews:

### Step 1: Execute Unified Security Audit
```bash
./bin/serveradmin security audit
```
*Expected Result*:
- SSH Root Login: `PASS (Disabled)`
- SSH Password Authentication: `PASS (Disabled)`
- No databases or internal services bound to `0.0.0.0`

### Step 2: Verify Firewall State
```bash
sudo ufw status verbose
```
*Expected Output*:
```
Status: active
Logging: on (low)
Default: deny (incoming), allow (outgoing), disabled (routed)
New profiles: skip

To                         Action      From
--                         ------      ----
22/tcp                     LIMIT IN    Anywhere (Rate-limited SSH)
80/tcp                     ALLOW IN    Anywhere (HTTP)
443/tcp                    ALLOW IN    Anywhere (HTTPS)
```

### Step 3: Verify Container Non-Root Execution
```bash
docker compose -f app_stack/docker-compose.yml exec web_app id
```
*Expected Result*: `uid=1000(node) gid=1000(node)` (NOT `uid=0(root)`).

---

## 3. Disaster Recovery & Backup Restoration Procedure

In the event of system corruption or accidental deletion, follow this procedure to restore configuration and application state.

### Step 1: Identify and Verify the Target Archive
```bash
# List available backups in destination
ls -lh /var/backups/serveradmin/

# Verify the SHA-256 checksum and tar integrity of the target archive
./scripts/backup_engine.sh --dest /var/backups/serveradmin --verify /var/backups/serveradmin/backup_YYYYMMDD_HHMMSS.tar.gz
```

### Step 2: Perform Dry-Run Extraction
```bash
# Dry run to inspect archive contents without modifying live directories
./scripts/backup_engine.sh --restore /var/backups/serveradmin/backup_YYYYMMDD_HHMMSS.tar.gz --restore-to /tmp/restore_test --dry-run
```

### Step 3: Execute Restoration to Live Environment
```bash
# Restore files to desired target
sudo ./scripts/backup_engine.sh --restore /var/backups/serveradmin/backup_YYYYMMDD_HHMMSS.tar.gz --restore-to /
```

### Step 4: Restart and Validate Services
```bash
sudo systemctl restart nginx
docker compose -f app_stack/docker-compose.yml restart
./bin/serveradmin status
```

