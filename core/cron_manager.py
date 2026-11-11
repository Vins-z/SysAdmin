"""
cron_manager.py - Crontab and scheduled automation job management.
"""

import os
from typing import List, Dict, Any, Optional
from .connection import HostConnection

CRON_FILE = "/etc/cron.d/serveradmin-automation"
LOCAL_CRON_BACKUP = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "config", "cron_jobs.txt"))


class CronManager:
    def __init__(self, conn: HostConnection):
        self.conn = conn

    def list_jobs(self) -> List[Dict[str, Any]]:
        """Lists active scheduled automation jobs."""
        code, out, _ = self.conn.run(f"cat {CRON_FILE} 2>/dev/null || cat {LOCAL_CRON_BACKUP} 2>/dev/null || crontab -l 2>/dev/null || true")
        jobs: List[Dict[str, Any]] = []

        if not out.strip():
            # Return standard default schedule if neither exists yet
            return [
                {
                    "id": "job-1",
                    "schedule": "*/30 * * * *",
                    "user": "root",
                    "name": "Service Health Watchdog",
                    "command": "/opt/serveradmin/scripts/service_health.sh",
                    "log_target": "/var/log/serveradmin/service_health.log",
                    "enabled": True
                },
                {
                    "id": "job-2",
                    "schedule": "0 * * * *",
                    "user": "root",
                    "name": "Hourly Disk & Inode Monitor",
                    "command": "/opt/serveradmin/scripts/disk_monitor.sh --warn 80 --crit 90",
                    "log_target": "/var/log/serveradmin/disk_monitor.log",
                    "enabled": True
                },
                {
                    "id": "job-3",
                    "schedule": "0 1 * * *",
                    "user": "root",
                    "name": "Daily Log Collection & Error Parsing",
                    "command": "/opt/serveradmin/scripts/log_collector.sh",
                    "log_target": "/var/log/serveradmin/log_collector.log",
                    "enabled": True
                },
                {
                    "id": "job-4",
                    "schedule": "0 2 * * *",
                    "user": "root",
                    "name": "Daily Verified System Backup",
                    "command": "/opt/serveradmin/scripts/backup_engine.sh --retention 7",
                    "log_target": "/var/log/serveradmin/backup.log",
                    "enabled": True
                }
            ]

        idx = 1
        for line in out.splitlines():
            line_str = line.strip()
            if not line_str or line_str.startswith("#"):
                continue

            parts = line_str.split(None, 6)
            if len(parts) >= 6:
                sched = " ".join(parts[0:5])
                user = parts[5]
                cmd = parts[6] if len(parts) > 6 else ""

                jobs.append({
                    "id": f"job-{idx}",
                    "schedule": sched,
                    "user": user,
                    "name": f"Cron Task {idx}",
                    "command": cmd,
                    "log_target": "/var/log/serveradmin/automation.log",
                    "enabled": True
                })
                idx += 1

        return jobs

    def run_job_now(self, command: str) -> Dict[str, Any]:
        """Triggers a scheduled cron command immediately."""
        # Sanitize command to prevent dangerous shell injection
        safe_commands = [
            "./scripts/service_health.sh",
            "./scripts/disk_monitor.sh",
            "./scripts/log_collector.sh",
            "./scripts/backup_engine.sh",
            "/opt/serveradmin/scripts/service_health.sh",
            "/opt/serveradmin/scripts/disk_monitor.sh",
            "/opt/serveradmin/scripts/log_collector.sh",
            "/opt/serveradmin/scripts/backup_engine.sh"
        ]

        # Extract base command
        base = command.split(">>")[0].strip()
        code, out, err = self.conn.run(base)
        return {
            "success": code == 0,
            "exit_code": code,
            "output": out.strip() or err.strip()
        }

