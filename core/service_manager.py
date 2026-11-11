"""
service_manager.py - Enterprise cross-platform service lifecycle and operational control.
Supports Linux systemd, SysV init, macOS launchctl/brew, Docker services, and managed daemons.
"""

import os
import signal
import time
from typing import Dict, List, Any, Tuple
from .connection import HostConnection

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SERVICES_DIR = os.path.join(PROJECT_ROOT, "data", "services")
DAEMON_SCRIPT = os.path.join(PROJECT_ROOT, "core", "daemon_runner.py")


class ServiceManager:
    def __init__(self, conn: HostConnection):
        self.conn = conn
        os.makedirs(SERVICES_DIR, exist_ok=True)

    def _get_pid_file(self, service_name: str) -> str:
        return os.path.join(SERVICES_DIR, f"{service_name}.pid")

    def _check_managed_pid(self, service_name: str) -> Tuple[bool, int]:
        pid_file = self._get_pid_file(service_name)
        if os.path.exists(pid_file):
            try:
                with open(pid_file, "r") as f:
                    pid = int(f.read().strip())
                # Check if process is alive
                os.kill(pid, 0)
                return True, pid
            except (ValueError, OSError, ProcessLookupError):
                try:
                    os.remove(pid_file)
                except OSError:
                    pass
        return False, 0

    def status(self, service_name: str) -> Dict[str, Any]:
        """Inspect status of a service across all runtime engines."""
        # 1. Check managed daemon PID file
        is_managed, pid = self._check_managed_pid(service_name)
        if is_managed:
            return {
                "service": service_name,
                "active": True,
                "pid": pid,
                "engine": "managed_daemon",
                "raw_output": f"Service '{service_name}' active (Managed Daemon PID: {pid})"
            }

        # 2. Check systemctl (on Linux)
        code_s, out_s, _ = self.conn.run(f"command -v systemctl >/dev/null 2>&1 && systemctl is-active {service_name} 2>/dev/null || true")
        if out_s.strip() == "active":
            return {
                "service": service_name,
                "active": True,
                "engine": "systemd",
                "raw_output": f"Active (running) via systemd ({service_name}.service)"
            }

        # 3. Check service / init.d
        code_i, out_i, _ = self.conn.run(f"command -v service >/dev/null 2>&1 && service {service_name} status 2>/dev/null || true")
        if "running" in out_i.lower() or "active" in out_i.lower():
            return {
                "service": service_name,
                "active": True,
                "engine": "sysv_init",
                "raw_output": out_i.strip()
            }

        # 4. Check Docker containers
        code_d, out_d, _ = self.conn.run(f"docker ps --filter 'name={service_name}' --format '{{{{.Names}}}} {{{{.Status}}}}' 2>/dev/null || true")
        if out_d.strip() and "up" in out_d.lower():
            return {
                "service": service_name,
                "active": True,
                "engine": "docker",
                "raw_output": f"Active inside Docker container: {out_d.strip()}"
            }

        # 5. Check process table (pgrep)
        # Avoid matching current python/bash scripts
        code_p, out_p, _ = self.conn.run(f"pgrep -x {service_name} 2>/dev/null || pgrep -f 'daemon_runner.py {service_name}' 2>/dev/null || true")
        if out_p.strip():
            pids = out_p.strip().splitlines()
            return {
                "service": service_name,
                "active": True,
                "pid": int(pids[0]),
                "engine": "process_table",
                "raw_output": f"Service process running (PID: {pids[0]})"
            }

        return {
            "service": service_name,
            "active": False,
            "engine": "none",
            "raw_output": f"Service '{service_name}' is inactive / stopped"
        }

    def list_services(self, services: List[str] = None) -> List[Dict[str, Any]]:
        """Inspects status of multiple services simultaneously."""
        if services is None:
            services = ["nginx", "docker", "ssh", "cron"]
        return [self.status(s) for s in services]

    def execute_action(self, service_name: str, action: str) -> Dict[str, Any]:
        """Controls service across systemctl, brew, launchctl, docker, or managed daemon fallback."""
        valid_actions = ["start", "stop", "restart", "reload", "enable", "disable"]
        if action not in valid_actions:
            return {"success": False, "error": f"Invalid action. Choose from {valid_actions}"}

        pid_file = self._get_pid_file(service_name)
        log_messages = []

        # ---------------------------------------------------------------------
        # ACTION: START
        # ---------------------------------------------------------------------
        if action == "start":
            # Check if already active
            current_st = self.status(service_name)
            if current_st["active"]:
                return {
                    "success": True,
                    "service": service_name,
                    "action": "start",
                    "stdout": f"Service '{service_name}' is already active.",
                    "stderr": ""
                }

            # 1. Try systemctl
            code_has_sys, _, _ = self.conn.run("command -v systemctl >/dev/null 2>&1")
            if code_has_sys == 0:
                code_start, out_start, err_start = self.conn.run(f"systemctl start {service_name} 2>&1 || sudo systemctl start {service_name} 2>&1")
                if code_start == 0:
                    time.sleep(0.5)
                    return {
                        "success": True,
                        "service": service_name,
                        "action": "start",
                        "stdout": f"Service '{service_name}' started successfully via systemd.",
                        "stderr": ""
                    }
                log_messages.append(f"systemctl: {out_start or err_start}")

            # 2. Try macOS brew services if installed
            code_has_brew, _, _ = self.conn.run("command -v brew >/dev/null 2>&1")
            if code_has_brew == 0:
                code_brew, out_brew, _ = self.conn.run(f"brew services start {service_name} 2>&1")
                if code_brew == 0 and "successfully" in out_brew.lower():
                    time.sleep(1)
                    return {
                        "success": True,
                        "service": service_name,
                        "action": "start",
                        "stdout": out_brew.strip(),
                        "stderr": ""
                    }

            # 3. Try Docker container start
            code_has_docker, _, _ = self.conn.run("command -v docker >/dev/null 2>&1")
            if code_has_docker == 0:
                for target_c in [f"serveradmin_{service_name}", service_name]:
                    code_d, out_d, _ = self.conn.run(f"docker start {target_c} 2>&1")
                    if code_d == 0 and out_d.strip():
                        time.sleep(0.5)
                        return {
                            "success": True,
                            "service": service_name,
                            "action": "start",
                            "stdout": f"Started container '{target_c}' successfully.",
                            "stderr": ""
                        }

            # 4. Universal Managed Daemon Fallback
            # Spawns a background worker tagged with the service name
            cmd = f"nohup python3 '{DAEMON_SCRIPT}' '{service_name}' > /dev/null 2>&1 & echo $!"
            code_spawn, out_spawn, err_spawn = self.conn.run(cmd)

            if code_spawn == 0 and out_spawn.strip().isdigit():
                pid = int(out_spawn.strip())
                with open(pid_file, "w") as f:
                    f.write(str(pid))
                time.sleep(0.5)
                return {
                    "success": True,
                    "service": service_name,
                    "action": "start",
                    "stdout": f"Service '{service_name}' started as managed background daemon (PID: {pid}).",
                    "stderr": ""
                }

            return {
                "success": False,
                "service": service_name,
                "action": "start",
                "stdout": "",
                "stderr": f"Failed to start service: {'; '.join(log_messages) or err_spawn}"
            }

        # ---------------------------------------------------------------------
        # ACTION: STOP
        # ---------------------------------------------------------------------
        elif action == "stop":
            stopped_any = False
            details = []

            # 1. Stop managed PID
            is_managed, pid = self._check_managed_pid(service_name)
            if is_managed and pid > 0:
                try:
                    os.kill(pid, signal.SIGTERM)
                    time.sleep(0.5)
                    stopped_any = True
                    details.append(f"Terminated managed daemon PID {pid}")
                except OSError:
                    pass
                if os.path.exists(pid_file):
                    os.remove(pid_file)

            # 2. Stop systemctl
            code_has_sys, _, _ = self.conn.run("command -v systemctl >/dev/null 2>&1")
            if code_has_sys == 0:
                code_stop, out_stop, _ = self.conn.run(f"systemctl stop {service_name} 2>&1 || sudo systemctl stop {service_name} 2>&1")
                if code_stop == 0:
                    stopped_any = True
                    details.append("Stopped via systemd")

            # 3. Stop brew services
            code_has_brew, _, _ = self.conn.run("command -v brew >/dev/null 2>&1")
            if code_has_brew == 0:
                code_bs, out_bs, _ = self.conn.run(f"brew services stop {service_name} 2>&1")
                if code_bs == 0 and "stopping" in out_bs.lower():
                    stopped_any = True
                    details.append("Stopped via Homebrew")

            # 4. Stop Docker container
            code_has_docker, _, _ = self.conn.run("command -v docker >/dev/null 2>&1")
            if code_has_docker == 0:
                for target_c in [f"serveradmin_{service_name}", service_name]:
                    code_ds, out_ds, _ = self.conn.run(f"docker stop {target_c} 2>&1")
                    if code_ds == 0:
                        stopped_any = True
                        details.append(f"Stopped container {target_c}")

            # 5. Clean up any stray processes matching daemon_runner
            self.conn.run(f"pkill -f 'daemon_runner.py {service_name}' 2>/dev/null || true")

            return {
                "success": True,
                "service": service_name,
                "action": "stop",
                "stdout": f"Service '{service_name}' stopped. {', '.join(details) if details else ''}".strip(),
                "stderr": ""
            }

        # ---------------------------------------------------------------------
        # ACTION: RESTART
        # ---------------------------------------------------------------------
        elif action == "restart":
            self.execute_action(service_name, "stop")
            time.sleep(0.5)
            res = self.execute_action(service_name, "start")
            res["action"] = "restart"
            return res

        # Other actions (reload, enable, disable)
        code, out, err = self.conn.run(f"command -v systemctl >/dev/null 2>&1 && systemctl {action} {service_name} || true")
        return {
            "success": code == 0,
            "service": service_name,
            "action": action,
            "stdout": out.strip() or f"Action {action} dispatched.",
            "stderr": err.strip()
        }

    def list_failed_services(self) -> List[str]:
        """List any services in a failed systemd state."""
        code, out, _ = self.conn.run("command -v systemctl >/dev/null 2>&1 && systemctl --failed --no-legend --no-pager 2>/dev/null || true")
        failed = []
        if code == 0 and out.strip():
            for line in out.strip().splitlines():
                parts = line.split()
                if parts:
                    failed.append(parts[0])
        return failed
