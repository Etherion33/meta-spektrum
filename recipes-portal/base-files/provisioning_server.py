#!/usr/bin/env python3
import argparse
from datetime import datetime, timezone
import json
import os
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import threading
from urllib.parse import urlparse

from state_store import StateStore

WLAN_IFACE = os.environ.get("SPEKTRUM_WLAN_IFACE", "wlan0")
SWITCH_SCRIPT = Path(__file__).with_name("switch_to_sta.sh")
LOG_COLLECT_SCRIPT = Path(__file__).with_name("collect_logs.sh")
PORTAL_DIR = Path(__file__).with_name("portal")
EXIT_AFTER_CONFIGURE = False
STATE_DB = Path(os.environ.get("SPEKTRUM_STATE_DB", "/var/lib/spektrum/device_state.db"))
LOG_DIR = Path("/var/lib/spektrum/logs")
store = StateStore(STATE_DB)


def scan_ssids() -> list[str]:
    try:
        output = subprocess.check_output(
            ["nmcli", "-t", "-f", "SSID", "dev", "wifi", "list"], text=True
        )
        names = [line.strip() for line in output.splitlines() if line.strip()]
        # Preserve order while deduplicating.
        return list(dict.fromkeys(names))
    except Exception:
        return []


class Handler(BaseHTTPRequestHandler):
    def _send_json(self, payload: dict, status: int = 200) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_static_file(self, file_path: Path, content_type: str) -> None:
        if not file_path.exists():
            self._send_json({"message": f"Missing asset: {file_path.name}"}, status=500)
            return
        data = file_path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _send_download(self, file_path: Path, content_type: str, filename: str) -> None:
        data = file_path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Disposition", f'attachment; filename="{filename}"')
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:  # noqa: N802
        path = urlparse(self.path).path

        if path == "/":
            self._send_static_file(PORTAL_DIR / "index.html", "text/html; charset=utf-8")
            return

        if path == "/styles.css":
            self._send_static_file(PORTAL_DIR / "styles.css", "text/css; charset=utf-8")
            return

        if path == "/app.js":
            self._send_static_file(PORTAL_DIR / "app.js", "application/javascript; charset=utf-8")
            return

        if path == "/scan":
            ssids = scan_ssids()
            if ssids:
                self._send_json({"ssids": ssids, "message": "Scan successful"})
            else:
                self._send_json(
                    {
                        "ssids": [],
                        "message": "No SSIDs found while in AP mode. This is expected on some chipsets; enter SSID manually.",
                    }
                )
            return

        if path == "/state":
            self._send_json(
                {
                    "device_id": store.get("device_id"),
                    "paired": store.get("paired", "0") == "1",
                    "pair_code": store.get("pair_code"),
                    "pair_code_expires_at": store.get("pair_code_expires_at"),
                    "backend_http": store.get("backend_http"),
                    "name": store.get("name"),
                    "video_device": store.get("video_device", "/dev/video0"),
                    "stream_status": store.get("stream_status", ""),
                    "stream_detail": store.get("stream_detail", ""),
                }
            )
            return

        if path == "/logs/download":
            try:
                LOG_DIR.mkdir(parents=True, exist_ok=True)
                result = subprocess.check_output(
                    ["bash", str(LOG_COLLECT_SCRIPT), str(LOG_DIR), str(STATE_DB)],
                    text=True,
                    timeout=40,
                ).strip()
                bundle = Path(result)
                if not bundle.exists():
                    raise RuntimeError("log bundle not created")
                self._send_download(bundle, "application/gzip", bundle.name)
            except Exception as exc:
                self._send_json({"message": f"Failed to generate logs: {exc}"}, status=500)
            return

        self._send_json({"message": "Not found"}, status=404)

    def do_POST(self) -> None:  # noqa: N802
        if self.path == "/unpair":
            store.set_many(
                {
                    "paired": "0",
                    "pair_code": "",
                    "pair_code_expires_at": "",
                    "stream_status": "idle",
                    "stream_detail": "",
                }
            )
            self._send_json({"message": "Device unpaired. It will re-register on next connection."})
            return

        if self.path == "/factory-reset":
            with store._connect() as conn:
                conn.execute("DELETE FROM state")
                conn.commit()
            self._send_json({"message": "Factory reset complete. Restart or power-cycle the device to re-enter provisioning mode."})
            return

        if self.path != "/configure":
            self._send_json({"message": "Not found"}, status=404)
            return

        length = int(self.headers.get("Content-Length", "0"))
        payload = json.loads(self.rfile.read(length).decode("utf-8"))

        ssid = str(payload.get("ssid", "")).strip()
        password = str(payload.get("password", ""))
        backend_http = str(payload.get("backend_http", "")).strip().rstrip("/")

        if not ssid or not backend_http:
            self._send_json({"message": "ssid and backend_http are required"}, status=400)
            return

        backend_ws = backend_http.replace("http://", "ws://").replace("https://", "wss://")
        store.set_many(
            {
                "wifi_ssid": ssid,
                "wifi_password": password,
                "wifi_interface": WLAN_IFACE,
                "backend_http": backend_http,
                "backend_ws": backend_ws,
                "name": str(payload.get("name", "")).strip(),
                "video_device": str(payload.get("video_device", "/dev/video0")).strip() or "/dev/video0",
                "last_configured_at": datetime.now(timezone.utc).isoformat(),
            }
        )

        self._send_json(
            {
                "message": "Saved. Device will apply these settings shortly. Keep this page for device status and pairing code.",
            }
        )

        if EXIT_AFTER_CONFIGURE:
            # Boot-managed mode: let autonomous_bootstrap.sh handle the STA
            # switch via try_join_sta() once this server exits.
            # server.shutdown() must be called from a different thread to
            # avoid deadlocking with serve_forever().
            threading.Timer(1.5, self.server.shutdown).start()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="SBC provisioning web server")
    parser.add_argument(
        "--exit-after-configure",
        action="store_true",
        help="Stop the server after successful /configure to continue autonomous boot flow",
    )
    parser.add_argument(
        "--state-db",
        default="/var/lib/spektrum/device_state.db",
        help="Path to internal SQLite state database",
    )
    parser.add_argument(
        "--host",
        default="0.0.0.0",
        help="HTTP bind host",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=80,
        help="HTTP bind port",
    )
    return parser.parse_args()


if __name__ == "__main__":
    args = parse_args()
    EXIT_AFTER_CONFIGURE = bool(args.exit_after_configure)
    db_path = Path(args.state_db)
    store = StateStore(db_path)
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"Provisioning server running at http://{args.host}:{args.port}")
    server.serve_forever()
