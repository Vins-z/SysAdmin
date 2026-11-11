"""
alerts.py - Automated webhook alerting and notification dispatcher.
"""

import os
import json
import urllib.request
import urllib.error
import time
from typing import Dict, Any, Optional

CONFIG_PATH = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "config", "alerts.json"))


class AlertNotifier:
    def __init__(self, config_path: str = CONFIG_PATH):
        self.config_path = config_path

    def get_config(self) -> Dict[str, Any]:
        if os.path.exists(self.config_path):
            try:
                with open(self.config_path, "r") as f:
                    return json.load(f)
            except Exception:
                pass
        return {"enabled": False, "webhook_url": ""}

    def save_config(self, cfg: Dict[str, Any]) -> bool:
        try:
            with open(self.config_path, "w") as f:
                json.dump(cfg, f, indent=2)
            return True
        except Exception:
            return False

    def send_notification(self, title: str, message: str, level: str = "INFO", details: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        cfg = self.get_config()
        webhook_url = cfg.get("webhook_url", "").strip()

        if not webhook_url:
            return {"sent": False, "reason": "No webhook URL configured"}

        payload = {
            "source": "ServerAdmin Control Platform",
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "level": level,
            "title": title,
            "message": message,
            "details": details or {}
        }

        # Adapt for Discord/Slack if detected
        data_to_send = json.dumps(payload).encode('utf-8')
        if "discord.com/api/webhooks" in webhook_url:
            color = 0x38bdf8 if level == "INFO" else (0xf59e0b if level == "WARNING" else 0xef4444)
            discord_payload = {
                "content": f"**[ServerAdmin Alert - {level}]** {title}",
                "embeds": [{
                    "title": title,
                    "description": message,
                    "color": color,
                    "timestamp": payload["timestamp"]
                }]
            }
            data_to_send = json.dumps(discord_payload).encode('utf-8')
        elif "hooks.slack.com" in webhook_url:
            slack_payload = {
                "text": f"*[ServerAdmin {level}]* {title}\n{message}"
            }
            data_to_send = json.dumps(slack_payload).encode('utf-8')

        req = urllib.request.Request(
            webhook_url,
            data=data_to_send,
            headers={'Content-Type': 'application/json', 'User-Agent': 'ServerAdmin-AlertEngine/1.0'}
        )

        try:
            with urllib.request.urlopen(req, timeout=10) as response:
                status_code = response.getcode()
                return {"sent": 200 <= status_code < 300, "status_code": status_code}
        except urllib.error.HTTPError as e:
            return {"sent": False, "status_code": e.code, "error": str(e)}
        except Exception as e:
            return {"sent": False, "error": str(e)}

