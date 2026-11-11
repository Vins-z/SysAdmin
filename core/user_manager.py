"""
user_manager.py - User and group administration with least-privilege standards.
"""

from typing import List, Dict, Optional
from .connection import HostConnection


class UserManager:
    def __init__(self, conn: HostConnection):
        self.conn = conn

    def list_users(self, min_uid: int = 1000) -> List[Dict[str, str]]:
        """List human/interactive users on the server (UID >= 1000)."""
        code, out, _ = self.conn.run("getent passwd || cat /etc/passwd")
        users = []
        if code == 0:
            for line in out.strip().splitlines():
                parts = line.split(":")
                if len(parts) >= 7:
                    try:
                        uid = int(parts[2])
                        # Filter to standard users plus root
                        if uid >= min_uid or uid == 0:
                            users.append({
                                "username": parts[0],
                                "uid": parts[2],
                                "gid": parts[3],
                                "home": parts[5],
                                "shell": parts[6]
                            })
                    except ValueError:
                        continue
        return users

    def add_user(
        self,
        username: str,
        group: Optional[str] = None,
        additional_groups: Optional[str] = None,
        ssh_pubkey: Optional[str] = None,
        sudo: bool = False,
        nopasswd: bool = False
    ) -> Dict[str, str]:
        """Provisions a user by executing scripts/setup_users.sh or direct commands."""
        args = ["./scripts/setup_users.sh", "-u", username]
        if group:
            args.extend(["-g", group])
        if additional_groups:
            args.extend(["-G", additional_groups])
        if ssh_pubkey:
            args.extend(["-k", f"'{ssh_pubkey}'"])
        if sudo:
            args.append("--sudo")
        if nopasswd:
            args.append("--nopasswd")

        cmd = " ".join(args)
        code, out, err = self.conn.run(cmd)
        return {"code": str(code), "stdout": out, "stderr": err}

    def lock_user(self, username: str) -> Dict[str, str]:
        """Locks a user account to revoke interactive authentication."""
        code, out, err = self.conn.run(f"passwd -l {username}")
        return {"code": str(code), "stdout": out, "stderr": err}

