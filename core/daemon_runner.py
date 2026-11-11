#!/usr/bin/env python3
"""
daemon_runner.py - Lightweight background daemon runner for local development and non-systemd environments.
"""

import sys
import os
import time
import signal

SERVICE_NAME = sys.argv[1] if len(sys.argv) > 1 else "generic"
LOG_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "data", "services"))
os.makedirs(LOG_DIR, exist_ok=True)
LOG_FILE = os.path.join(LOG_DIR, f"{SERVICE_NAME}.log")

running = True


def handle_signal(sig, frame):
    global running
    with open(LOG_FILE, "a") as f:
        f.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] Received signal {sig}, terminating gracefully...\n")
    running = False
    sys.exit(0)


signal.signal(signal.SIGTERM, handle_signal)
signal.signal(signal.SIGINT, handle_signal)

with open(LOG_FILE, "a") as f:
    f.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] Daemon for service '{SERVICE_NAME}' started (PID: {os.getpid()}).\n")

while running:
    time.sleep(2)
    # Heartbeat
    try:
        with open(LOG_FILE, "a") as f:
            f.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] [{SERVICE_NAME}] Heartbeat OK\n")
    except Exception:
        pass

