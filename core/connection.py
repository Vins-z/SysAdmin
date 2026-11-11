"""
connection.py - Unified execution interface for local and remote SSH commands.
"""

import subprocess
import shlex
import sys
from typing import Tuple, Optional


class HostConnection:
    def __init__(
        self,
        remote_host: Optional[str] = None,
        remote_user: Optional[str] = None,
        key_file: Optional[str] = None,
        port: int = 22,
        connect_timeout: int = 10
    ):
        self.remote_host = remote_host
        self.remote_user = remote_user
        self.key_file = key_file
        self.port = port
        self.connect_timeout = connect_timeout

    @property
    def is_remote(self) -> bool:
        return bool(self.remote_host)

    def run(self, cmd: str, check: bool = False) -> Tuple[int, str, str]:
        """
        Executes a command either locally or remotely over SSH.
        Returns: (exit_code, stdout, stderr)
        """
        if self.is_remote:
            ssh_target = f"{self.remote_user}@{self.remote_host}" if self.remote_user else self.remote_host
            ssh_args = [
                "ssh",
                "-o", f"ConnectTimeout={self.connect_timeout}",
                "-o", "BatchMode=yes",
                "-o", "StrictHostKeyChecking=accept-new",
                "-p", str(self.port)
            ]
            if self.key_file:
                ssh_args.extend(["-i", self.key_file])
            ssh_args.extend([ssh_target, cmd])
            exec_args = ssh_args
        else:
            exec_args = ["bash", "-c", cmd]

        try:
            res = subprocess.run(
                exec_args,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=check
            )
            return res.returncode, res.stdout, res.stderr
        except subprocess.CalledProcessError as e:
            return e.returncode, e.stdout, e.stderr
        except Exception as e:
            return -1, "", str(e)

