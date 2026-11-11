"""
security.py - Security auditing, open port analysis, and firewall management.
"""

from typing import Dict, Any, List
from .connection import HostConnection


class SecurityAuditor:
    def __init__(self, conn: HostConnection):
        self.conn = conn

    def audit_security(self) -> Dict[str, Any]:
        """Runs the security audit script and inspects host configurations."""
        code, out, _ = self.conn.run("./scripts/firewall_setup.sh audit -j")
        audit_data = {}
        if code == 0 and out.strip().startswith("{"):
            import json
            try:
                audit_data = json.loads(out)
            except Exception:
                audit_data = {"raw_output": out}
        else:
            audit_data = {"raw_output": out}

        # SSH Configuration check
        ssh_checks = {
            "root_login_disabled": False,
            "password_auth_disabled": False,
            "pubkey_auth_enabled": True
        }

        code_ssh, out_ssh, _ = self.conn.run("cat /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null")
        if code_ssh == 0:
            for line in out_ssh.splitlines():
                clean_line = line.strip()
                if clean_line.startswith("#"):
                    continue
                if "PermitRootLogin" in clean_line and ("no" in clean_line or "prohibit-password" in clean_line):
                    ssh_checks["root_login_disabled"] = True
                if "PasswordAuthentication" in clean_line and "no" in clean_line:
                    ssh_checks["password_auth_disabled"] = True

        audit_data["ssh_compliance"] = ssh_checks
        return audit_data

    def apply_firewall(self, ssh_port: int = 22, allow_http: bool = True, allow_https: bool = True) -> Dict[str, Any]:
        """Applies standard UFW firewall baseline."""
        args = ["./scripts/firewall_setup.sh", "apply", "--ssh-port", str(ssh_port)]
        if not allow_http:
            args.append("--no-http")
        if not allow_https:
            args.append("--no-https")

        code, out, err = self.conn.run(" ".join(args))
        return {
            "success": code == 0,
            "stdout": out.strip(),
            "stderr": err.strip()
        }

