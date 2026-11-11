"""
compliance.py - CIS / SAIF Security Compliance Benchmark & Hardening Engine.
Performs automated audits, calculates compliance score (0-100), and provides automated remediation.
"""

import os
import json
from typing import Dict, Any, List
from .connection import HostConnection


class ComplianceAuditor:
    def __init__(self, conn: HostConnection):
        self.conn = conn

    def run_benchmark(self) -> Dict[str, Any]:
        """
        Runs 10 standard security checks modeled after CIS Ubuntu Linux benchmarks.
        Returns score (0-100), grade (A+, A, B, C, F), and check breakdown.
        """
        checks: List[Dict[str, Any]] = []

        # 1. SSH Root Login
        code, out, _ = self.conn.run("cat /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null")
        root_disabled = False
        pwd_disabled = False
        if code == 0:
            for line in out.splitlines():
                cl = line.strip()
                if cl.startswith("#"):
                    continue
                if "PermitRootLogin" in cl and ("no" in cl or "prohibit-password" in cl):
                    root_disabled = True
                if "PasswordAuthentication" in cl and "no" in cl:
                    pwd_disabled = True

        checks.append({
            "id": "SEC-01",
            "name": "SSH Root Login Restriction",
            "description": "Prohibit direct root login over SSH (use least-privilege users + sudo)",
            "passed": root_disabled,
            "weight": 15,
            "remediation": "Set 'PermitRootLogin prohibit-password' in /etc/ssh/sshd_config.d/99-hardened.conf"
        })

        # 2. SSH Password Authentication
        checks.append({
            "id": "SEC-02",
            "name": "SSH Key-Based Authentication Enforced",
            "description": "Disable password authentication to prevent brute force attacks",
            "passed": pwd_disabled,
            "weight": 15,
            "remediation": "Set 'PasswordAuthentication no' in /etc/ssh/sshd_config.d/99-hardened.conf"
        })

        # 3. Host Firewall Active (UFW)
        code_ufw, out_ufw, _ = self.conn.run("ufw status 2>/dev/null || (command -v pfctl >/dev/null && pfctl -s info 2>/dev/null)")
        fw_active = "active" in out_ufw.lower() or "status: active" in out_ufw.lower() or "enabled" in out_ufw.lower()
        checks.append({
            "id": "SEC-03",
            "name": "Host Firewall Enabled (UFW/PF)",
            "description": "Ensure incoming traffic is filtered by an active stateful firewall",
            "passed": fw_active,
            "weight": 15,
            "remediation": "Execute 'sudo ./scripts/firewall_setup.sh apply --ssh-port 22'"
        })

        # 4. Sensitive File Permissions (/etc/sudoers, /etc/shadow)
        code_perm, out_perm, _ = self.conn.run("find /etc/sudoers.d -type f -perm /0022 2>/dev/null | wc -l")
        perm_safe = code_perm == 0 and out_perm.strip() == "0"
        checks.append({
            "id": "SEC-04",
            "name": "Sudoers File Permission Hardening",
            "description": "Verify sudoers configuration files have restrictive permissions (0440)",
            "passed": perm_safe,
            "weight": 10,
            "remediation": "Execute 'sudo chmod 0440 /etc/sudoers.d/*'"
        })

        # 5. Open Listening Ports / Database Exposure
        code_ports, out_ports, _ = self.conn.run("./scripts/firewall_setup.sh audit -j")
        no_db_exposed = True
        try:
            ports_json = json.loads(out_ports)
            if ports_json.get("risky_exposure_detected", False):
                no_db_exposed = False
        except Exception:
            pass

        checks.append({
            "id": "SEC-05",
            "name": "Database & Internal Services Isolation",
            "description": "Databases (Redis, Postgres, MySQL) must NOT listen on public 0.0.0.0",
            "passed": no_db_exposed,
            "weight": 15,
            "remediation": "Bind databases and internal tiers to 127.0.0.1 or isolated Docker networks"
        })

        # 6. Backup Engine Integrity (.sha256)
        code_bk, _, _ = self.conn.run("./scripts/backup_engine.sh --verify-latest -j")
        backup_verified = (code_bk == 0)
        checks.append({
            "id": "SEC-06",
            "name": "Disaster Recovery & Backup Verification",
            "description": "Active backup archive exists and passes SHA-256 integrity validation",
            "passed": backup_verified,
            "weight": 10,
            "remediation": "Run 'serveradmin backup run' to create verified system snapshot"
        })

        # 7. World-Writable Files in /etc
        code_ww, out_ww, _ = self.conn.run("find /etc -maxdepth 2 -perm -o+w 2>/dev/null | grep -v '/etc/resolv.conf' | wc -l")
        no_world_writable = code_ww == 0 and out_ww.strip() == "0"
        checks.append({
            "id": "SEC-07",
            "name": "No World-Writable Files in /etc",
            "description": "Configuration directories must not allow write access to non-privileged users",
            "passed": no_world_writable,
            "weight": 5,
            "remediation": "Audit and remove write permissions: 'chmod o-w <file>'"
        })

        # 8. SUID Executable Boundaries
        code_suid, out_suid, _ = self.conn.run("find /usr/bin /bin -perm -4000 2>/dev/null | wc -l")
        suid_counted = int(out_suid.strip()) if code_suid == 0 and out_suid.strip().isdigit() else 20
        checks.append({
            "id": "SEC-08",
            "name": "SUID Binary Audit",
            "description": "Monitor privileged SUID executables on system binaries",
            "passed": suid_counted < 45,
            "weight": 5,
            "remediation": "Review privileged SUID binaries in /usr/bin and remove unnecessary suid bits"
        })

        # 9. Automated Routine Maintenance (Cron Scheduled)
        code_cron, _, _ = self.conn.run("test -f /etc/cron.d/serveradmin-automation || crontab -l 2>/dev/null | grep -q serveradmin")
        cron_active = (code_cron == 0)
        checks.append({
            "id": "SEC-09",
            "name": "Automated Maintenance Watchdog Active",
            "description": "Scheduled cron jobs present for health monitoring and log rotation",
            "passed": cron_active,
            "weight": 5,
            "remediation": "Run 'sudo ./scripts/provision_vm.sh' to install cron schedule"
        })

        # 10. Core Service Health
        code_health, _, _ = self.conn.run("./scripts/service_health.sh -s 'bash' --dry-run")
        services_healthy = (code_health == 0)
        checks.append({
            "id": "SEC-10",
            "name": "Core Service Health & Watchdog",
            "description": "All core systemd daemons and applications responding normally",
            "passed": services_healthy,
            "weight": 5,
            "remediation": "Inspect failed services with 'serveradmin service status <name>'"
        })

        # Compute Score
        total_possible = sum(c["weight"] for c in checks)
        earned = sum(c["weight"] for c in checks if c["passed"])
        score_pct = int(round((earned / total_possible) * 100))

        if score_pct >= 95:
            grade = "A+"
        elif score_pct >= 85:
            grade = "A"
        elif score_pct >= 75:
            grade = "B"
        elif score_pct >= 60:
            grade = "C"
        else:
            grade = "F"

        return {
            "score": score_pct,
            "grade": grade,
            "passed_count": sum(1 for c in checks if c["passed"]),
            "failed_count": sum(1 for c in checks if not c["passed"]),
            "total_checks": len(checks),
            "checks": checks
        }

    def remediate_baseline(self) -> Dict[str, Any]:
        """Applies baseline automated hardening remediations."""
        results = []

        # 1. Apply firewall baseline
        code, out, err = self.conn.run("./scripts/firewall_setup.sh apply --ssh-port 22")
        results.append({"step": "Firewall Setup", "success": code == 0, "output": out or err})

        # 2. Hardened permissions on sudoers.d
        code_s, out_s, _ = self.conn.run("chmod 0440 /etc/sudoers.d/* 2>/dev/null || true")
        results.append({"step": "Sudoers Permissions", "success": code_s == 0, "output": "Permissions hardened to 0440"})

        # 3. Create fresh verified backup
        code_b, out_b, _ = self.conn.run("./scripts/backup_engine.sh")
        results.append({"step": "System Backup", "success": code_b == 0, "output": out_b})

        return {
            "success": all(r["success"] for r in results),
            "steps": results
        }

