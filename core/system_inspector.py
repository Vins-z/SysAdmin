"""
system_inspector.py - Inspect host metrics, processes, and operating environment.
"""

from typing import Dict, Any, List
from .connection import HostConnection
import json


class SystemInspector:
    def __init__(self, conn: HostConnection):
        self.conn = conn

    def get_overview(self) -> Dict[str, Any]:
        """Collect high level host statistics."""
        info = {
            "is_remote": self.conn.is_remote,
            "target": f"{self.conn.remote_user}@{self.conn.remote_host}" if self.conn.is_remote else "Localhost",
            "hostname": "Unknown",
            "os_release": "Unknown",
            "kernel": "Unknown",
            "uptime": "Unknown",
            "load_avg": "Unknown",
            "memory": {},
            "disk_summary": []
        }

        # Hostname
        code, out, _ = self.conn.run("hostname")
        if code == 0:
            info["hostname"] = out.strip()

        # Kernel
        code, out, _ = self.conn.run("uname -srm")
        if code == 0:
            info["kernel"] = out.strip()

        # OS Release
        code, out, _ = self.conn.run("cat /etc/os-release 2>/dev/null || sw_vers 2>/dev/null || uname -s")
        if code == 0:
            lines = out.strip().splitlines()
            for line in lines:
                if line.startswith("PRETTY_NAME="):
                    info["os_release"] = line.split("=", 1)[1].strip('"\'')
                    break
                elif "ProductName:" in line:
                    info["os_release"] = line.split(":", 1)[1].strip()
                    break
            if info["os_release"] == "Unknown" and lines:
                info["os_release"] = lines[0]

        # Uptime & Load Avg
        code, out, _ = self.conn.run("uptime")
        if code == 0:
            info["uptime"] = out.strip()

        # Memory (free -m on Linux, vm_stat fallback on macOS)
        code, out, _ = self.conn.run("free -m 2>/dev/null")
        if code == 0 and "Mem:" in out:
            lines = out.strip().splitlines()
            for line in lines:
                if line.startswith("Mem:"):
                    parts = line.split()
                    if len(parts) >= 4:
                        info["memory"] = {
                            "total_mb": parts[1],
                            "used_mb": parts[2],
                            "free_mb": parts[3]
                        }
        else:
            info["memory"] = {"status": "Available"}

        return info

    def get_top_processes(self, count: int = 10) -> List[Dict[str, str]]:
        """Fetch top CPU / Memory consuming processes."""
        code, out, _ = self.conn.run(f"ps aux --sort=-%cpu 2>/dev/null || ps aux -r")
        processes = []
        if code == 0:
            lines = out.strip().splitlines()
            if len(lines) > 1:
                headers = lines[0].split()
                for line in lines[1:count+1]:
                    parts = line.split(None, 10)
                    if len(parts) >= 11:
                        processes.append({
                            "user": parts[0],
                            "pid": parts[1],
                            "cpu": parts[2],
                            "mem": parts[3],
                            "command": parts[10]
                        })
        return processes

