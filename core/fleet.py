"""
fleet.py - Multi-node inventory management and distributed command dispatcher.
"""

import os
import json
import time
from typing import List, Dict, Any, Optional
from .connection import HostConnection

INVENTORY_PATH = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "config", "inventory.json"))


class FleetManager:
    def __init__(self, inventory_path: str = INVENTORY_PATH):
        self.inventory_path = inventory_path
        self._ensure_inventory()

    def _ensure_inventory(self):
        if not os.path.exists(self.inventory_path):
            os.makedirs(os.path.dirname(self.inventory_path), exist_ok=True)
            default_nodes = [
                {
                    "id": "node-local",
                    "name": "Local Master Node",
                    "host": "localhost",
                    "user": "local",
                    "port": 22,
                    "key_path": "",
                    "tags": ["master", "local"],
                    "is_local": True,
                    "status": "online",
                    "last_check": None
                }
            ]
            with open(self.inventory_path, "w") as f:
                json.dump(default_nodes, f, indent=2)

    def list_nodes(self) -> List[Dict[str, Any]]:
        try:
            with open(self.inventory_path, "r") as f:
                return json.load(f)
        except Exception:
            return []

    def get_node(self, node_id: str) -> Optional[Dict[str, Any]]:
        nodes = self.list_nodes()
        for node in nodes:
            if node["id"] == node_id:
                return node
        return None

    def add_node(
        self,
        name: str,
        host: str,
        user: str = "ubuntu",
        port: int = 22,
        key_path: str = "",
        tags: Optional[List[str]] = None
    ) -> Dict[str, Any]:
        nodes = self.list_nodes()
        import re
        slug = re.sub(r'[^a-zA-Z0-9_-]', '', name.lower().replace(" ", "-"))
        node_id = f"node-{slug}-{int(time.time())}"

        is_local = host in ["localhost", "127.0.0.1"]
        new_node = {
            "id": node_id,
            "name": name,
            "host": host,
            "user": user,
            "port": port,
            "key_path": key_path,
            "tags": tags or ["worker"],
            "is_local": is_local,
            "status": "configured",
            "last_check": None
        }
        nodes.append(new_node)
        with open(self.inventory_path, "w") as f:
            json.dump(nodes, f, indent=2)
        return new_node

    def remove_node(self, node_id: str) -> bool:
        nodes = self.list_nodes()
        filtered = [n for n in nodes if n["id"] != node_id]
        if len(filtered) == len(nodes):
            return False
        with open(self.inventory_path, "w") as f:
            json.dump(filtered, f, indent=2)
        return True

    def ping_node(self, node_id: str) -> Dict[str, Any]:
        node = self.get_node(node_id)
        if not node:
            return {"node_id": node_id, "status": "not_found", "error": "Node not found"}

        conn = HostConnection(
            remote_host=None if node["is_local"] else node["host"],
            remote_user=node["user"],
            key_file=node["key_path"] or None,
            port=node.get("port", 22),
            connect_timeout=5
        )

        start = time.time()
        code, out, err = conn.run("hostname")
        latency_ms = round((time.time() - start) * 1000, 1)

        status = "online" if code == 0 else "offline"
        node["status"] = status
        node["last_check"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        node["latency_ms"] = latency_ms

        # Update in inventory
        nodes = self.list_nodes()
        for idx, n in enumerate(nodes):
            if n["id"] == node_id:
                nodes[idx] = node
                break
        with open(self.inventory_path, "w") as f:
            json.dump(nodes, f, indent=2)

        return {
            "node_id": node_id,
            "name": node["name"],
            "status": status,
            "latency_ms": latency_ms,
            "hostname": out.strip() if code == 0 else None,
            "error": err.strip() if code != 0 else None
        }

    def ping_all(self) -> List[Dict[str, Any]]:
        nodes = self.list_nodes()
        results = []
        for n in nodes:
            results.append(self.ping_node(n["id"]))
        return results

