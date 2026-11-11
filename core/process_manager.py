"""
process_manager.py - Interactive process inspection and process management.
"""

import signal
from typing import List, Dict, Any, Optional
from .connection import HostConnection


class ProcessManager:
    def __init__(self, conn: HostConnection):
        self.conn = conn

    def list_processes(self, limit: int = 50, sort_by: str = "cpu") -> List[Dict[str, Any]]:
        """Returns structured process list."""
        # Use ps aux
        code, out, _ = self.conn.run("ps aux")
        processes = []
        if code != 0:
            return processes

        lines = out.strip().splitlines()
        if len(lines) <= 1:
            return processes

        for line in lines[1:]:
            parts = line.split(None, 10)
            if len(parts) >= 11:
                try:
                    cpu = float(parts[2])
                    mem = float(parts[3])
                    rss = int(parts[5])
                except ValueError:
                    cpu = 0.0
                    mem = 0.0
                    rss = 0

                processes.append({
                    "user": parts[0],
                    "pid": int(parts[1]),
                    "cpu_pct": cpu,
                    "mem_pct": mem,
                    "rss_kb": rss,
                    "rss_mb": round(rss / 1024, 1),
                    "tty": parts[6],
                    "stat": parts[7],
                    "start": parts[8],
                    "time": parts[9],
                    "command": parts[10]
                })

        # Sort
        reverse = True
        key_fn = (lambda x: x["cpu_pct"]) if sort_by == "cpu" else (lambda x: x["mem_pct"])
        processes.sort(key=key_fn, reverse=reverse)
        return processes[:limit]

    def kill_process(self, pid: int, force: bool = False) -> Dict[str, Any]:
        """Sends SIGTERM or SIGKILL to target process."""
        # Safety: avoid killing PID 1 or self
        if pid <= 1:
            return {"success": False, "error": "Cannot kill system init PID 1"}

        sig = "KILL" if force else "TERM"
        cmd = f"kill -s {sig} {pid}"
        code, out, err = self.conn.run(cmd)

        return {
            "success": code == 0,
            "pid": pid,
            "signal": sig,
            "stdout": out.strip(),
            "stderr": err.strip()
        }

