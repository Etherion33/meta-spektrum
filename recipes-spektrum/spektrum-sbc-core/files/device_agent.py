#!/usr/bin/env python3
import argparse
import asyncio
from datetime import datetime, timedelta, timezone
import json
import re
import shutil
import signal
import subprocess
import time
from pathlib import Path
from urllib import error, parse, request

import websockets

from state_store import StateStore


def now_loop_seconds() -> float:
    return asyncio.get_running_loop().time()


class DeviceAgent:
    def __init__(self, state_db: Path) -> None:
        self.store = StateStore(state_db)
        self.stream_process: subprocess.Popen | None = None
        self.stop_requested = False
        self.stream_should_run = False
        self.next_stream_retry_at = 0.0
        self.camera_missing_count = 0
        self.last_usb_reset_at = 0.0
        self._current_stream_status = ""
        self._current_stream_detail = ""
        self._restart_requested = False

    def _set_stream_state(self, status: str, detail: str = "") -> None:
        self._current_stream_status = status
        self._current_stream_detail = detail
        self.store.set_many(
            {
                "stream_status": status,
                "stream_detail": detail,
            }
        )

    def _schedule_stream_retry(self, delay_seconds: float, reason: str) -> None:
        self.next_stream_retry_at = now_loop_seconds() + delay_seconds
        self._set_stream_state("retrying", reason)

    def _resolve_usb_device_id(self, video_device: str) -> str:
        if not video_device or not shutil.which("udevadm"):
            return ""

        try:
            probe = subprocess.run(
                ["udevadm", "info", "-q", "path", "-n", video_device],
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            )
            if probe.returncode != 0:
                return ""
            matches = re.findall(r"\b\d-\d(?:\.\d+)*\b", probe.stdout)
            return matches[-1] if matches else ""
        except Exception:
            return ""

    def _reset_usb_camera(self, video_device: str) -> bool:
        usb_device_id = self._resolve_usb_device_id(video_device)
        if not usb_device_id:
            print(f"usb reset skipped: unable to resolve USB device for {video_device}")
            return False

        try:
            authorized_path = Path(f"/sys/bus/usb/devices/{usb_device_id}/authorized")
            if authorized_path.exists():
                print(f"resetting usb camera via authorized toggle: {usb_device_id}")
                authorized_path.write_text("0")
                time.sleep(2)
                authorized_path.write_text("1")
            else:
                print(f"resetting usb camera via unbind/bind: {usb_device_id}")
                Path("/sys/bus/usb/drivers/usb/unbind").write_text(usb_device_id)
                time.sleep(2)
                Path("/sys/bus/usb/drivers/usb/bind").write_text(usb_device_id)
            self.last_usb_reset_at = now_loop_seconds()
            self._set_stream_state("recovering", f"Resetting USB camera {usb_device_id}")
            return True
        except Exception as exc:
            print(f"usb reset failed for {video_device}: {exc}")
            self._set_stream_state("error", f"USB reset failed for {video_device}: {exc}")
            return False

    def _cfg(self, key: str, default: str = "") -> str:
        return self.store.get(key, default)

    def _set_cfg(self, key: str, value: str) -> None:
        self.store.set(key, value)

    def _list_video_devices(self) -> list[str]:
        devices = []
        for path in Path("/dev").glob("video*"):
            if path.is_file() or path.exists():
                devices.append(str(path))

        def _sort_key(dev: str) -> tuple[int, str]:
            match = re.search(r"video(\d+)$", dev)
            if not match:
                return (10_000, dev)
            return (int(match.group(1)), dev)

        devices.sort(key=_sort_key)
        return devices

    def _is_capture_device(self, device: str) -> bool:
        if not Path(device).exists():
            return False

        if shutil.which("v4l2-ctl"):
            try:
                probe = subprocess.run(
                    ["v4l2-ctl", "--all", "-d", device],
                    capture_output=True,
                    text=True,
                    timeout=3,
                    check=False,
                )
                if probe.returncode != 0:
                    return False
                details = (probe.stdout + "\n" + probe.stderr).lower()
                if "video capture" not in details:
                    return False
                if "meta capture" in details and "video capture" not in details.replace("meta capture", ""):
                    return False
                return True
            except Exception:
                return False

        # Fallback when v4l2-ctl is unavailable: accept existing /dev/video* node.
        return True

    def _resolve_video_device(self) -> str:
        preferred = self._cfg("video_device", "/dev/video0").strip() or "/dev/video0"

        if self._is_capture_device(preferred):
            if self._can_stream_from_device(preferred):
                return preferred
            print(f"configured camera {preferred} cannot be opened by gstreamer")

        for candidate in self._list_video_devices():
            if self._is_capture_device(candidate):
                if self._can_stream_from_device(candidate):
                    print(f"camera fallback: {preferred} unavailable, using {candidate}")
                    self._set_cfg("video_device", candidate)
                    return candidate

        return ""

    def _can_stream_from_device(self, device: str) -> bool:
        if not shutil.which("gst-launch-1.0"):
            return True

        try:
            probe = subprocess.run(
                [
                    "gst-launch-1.0",
                    "-q",
                    "v4l2src",
                    f"device={device}",
                    "num-buffers=1",
                    "!",
                    "fakesink",
                ],
                capture_output=True,
                text=True,
                timeout=6,
                check=False,
            )
            return probe.returncode == 0
        except Exception:
            return False

    def _http_json(self, method: str, url: str, payload: dict | None = None) -> dict:
        body = None
        headers = {"Content-Type": "application/json"}
        if payload is not None:
            body = json.dumps(payload).encode("utf-8")
        req = request.Request(url, data=body, method=method, headers=headers)
        with request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read().decode("utf-8"))

    def register_device(self) -> dict:
        backend_http = self._cfg("backend_http").rstrip("/")
        payload = {
            "device_id": self._cfg("device_id") or None,
            "name": self._cfg("name") or None,
            "stream_path": self._cfg("stream_path") or None,
        }
        response = self._http_json("POST", f"{backend_http}/api/v1/devices/register", payload)
        self._set_cfg("device_id", response["device_id"])
        if not self._cfg("stream_path"):
            self._set_cfg("stream_path", response["device_id"])
        expires_in = int(response.get("expires_in", 0) or 0)
        pair_expiry = str(response.get("pair_expires_at", "") or "")
        if not pair_expiry and expires_in > 0:
            pair_expiry = (datetime.now(timezone.utc) + timedelta(seconds=expires_in)).isoformat()
        self.store.set_many(
            {
                "pair_code": str(response.get("pair_code", "")),
                "pair_code_expires_at": pair_expiry,
                "paired": "0",
            }
        )
        return response

    def is_paired(self) -> bool:
        backend_http = self._cfg("backend_http").rstrip("/")
        device_id = self._cfg("device_id")
        secret = parse.quote(self._cfg("device_secret"), safe="")
        url = f"{backend_http}/api/v1/devices/status?device_id={device_id}&device_secret={secret}"
        response = self._http_json("GET", url)
        paired = bool(response.get("paired"))
        if paired:
            self.store.set_many(
                {
                    "paired": "1",
                    "pair_code": "",
                    "pair_code_expires_at": "",
                }
            )
        return paired

    def start_stream(self) -> None:
        if self.stream_process and self.stream_process.poll() is None:
            return

        if now_loop_seconds() < self.next_stream_retry_at:
            return

        if shutil.which("gst-inspect-1.0"):
            probe = subprocess.run(
                ["gst-inspect-1.0", "rtspclientsink"],
                capture_output=True,
                text=True,
                check=False,
            )
            if probe.returncode != 0:
                print(
                    "missing gstreamer element 'rtspclientsink' (install gstreamer1.0-rtsp); "
                    "disabling stream auto-retry"
                )
                self._set_stream_state("error", "Missing gstreamer1.0-rtsp (rtspclientsink)")
                self.stream_should_run = False
                return

        video_device = self._resolve_video_device()
        if not video_device:
            print("no capture camera device found (checked /dev/video*)")
            self.camera_missing_count += 1
            configured_device = self._cfg("video_device", "").strip()
            if (
                configured_device
                and self.camera_missing_count >= 3
                and now_loop_seconds() - self.last_usb_reset_at >= 300
            ):
                self._reset_usb_camera(configured_device)
            self._schedule_stream_retry(30, "No capture camera device found")
            return
        self.camera_missing_count = 0

        stream_path = self._cfg("stream_path") or self._cfg("device_id")
        media_server_rtsp = self._cfg("media_server_rtsp")
        if not media_server_rtsp:
            backend_http = self._cfg("backend_http")
            parsed = parse.urlparse(backend_http)
            host = parsed.hostname or "127.0.0.1"
            media_server_rtsp = f"rtsp://{host}:8554"

        # Conservative defaults improve stability on low-power SBCs and UVC cams.
        capture_width = self._cfg("capture_width", "1280")
        capture_height = self._cfg("capture_height", "720")
        capture_fps = self._cfg("capture_fps", "15")

        use_mjpeg = False
        if shutil.which("v4l2-ctl"):
            try:
                caps = subprocess.run(
                    ["v4l2-ctl", "-d", video_device, "--list-formats-ext"],
                    capture_output=True,
                    text=True,
                    timeout=4,
                    check=False,
                )
                info = (caps.stdout + "\n" + caps.stderr).lower()
                use_mjpeg = "mjpg" in info or "jpeg" in info
            except Exception:
                use_mjpeg = False

        if use_mjpeg:
            print(f"starting stream pipeline (mjpeg mode) from {video_device}")
            pipeline = [
                "gst-launch-1.0",
                "-e",
                "v4l2src",
                f"device={video_device}",
                "io-mode=mmap",
                "do-timestamp=true",
                "!",
                f"image/jpeg,width={capture_width},height={capture_height},framerate={capture_fps}/1",
                "!",
                "jpegdec",
                "!",
                "videoconvert",
                "!",
                "video/x-raw,format=I420",
                "!",
                "queue",
                "max-size-buffers=4",
                "leaky=downstream",
                "!",
                "x264enc",
                "tune=zerolatency",
                "speed-preset=ultrafast",
                "threads=1",
                "bitrate=1200",
                "key-int-max=30",
                "!",
                "h264parse",
                "!",
                "rtspclientsink",
                "protocols=tcp",
                f"location={media_server_rtsp.rstrip('/')}/{stream_path}",
            ]
        else:
            print(f"starting stream pipeline (raw mode) from {video_device}")
            pipeline = [
                "gst-launch-1.0",
                "-e",
                "v4l2src",
                f"device={video_device}",
                "io-mode=mmap",
                "do-timestamp=true",
                "!",
                f"video/x-raw,width={capture_width},height={capture_height},framerate={capture_fps}/1",
                "!",
                "videoconvert",
                "!",
                "video/x-raw,format=I420",
                "!",
                "queue",
                "max-size-buffers=4",
                "leaky=downstream",
                "!",
                "x264enc",
                "tune=zerolatency",
                "speed-preset=ultrafast",
                "threads=1",
                "bitrate=1200",
                "key-int-max=30",
                "!",
                "h264parse",
                "!",
                "rtspclientsink",
                "protocols=tcp",
                f"location={media_server_rtsp.rstrip('/')}/{stream_path}",
            ]
        self.stream_process = subprocess.Popen(pipeline)
        self.next_stream_retry_at = 0.0
        self._set_stream_state("starting", f"Publishing from {video_device}")

    def stop_stream(self) -> None:
        self.stream_should_run = False
        self.next_stream_retry_at = 0.0
        if not self.stream_process:
            self._set_stream_state("idle", "")
            return
        if self.stream_process.poll() is None:
            self.stream_process.terminate()
            try:
                self.stream_process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.stream_process.kill()
        self.stream_process = None
        self._set_stream_state("idle", "")

    async def handle_command(self, payload: dict) -> dict:
        command = payload.get("command")
        command_payload = payload.get("payload") or {}

        if command == "reboot":
            subprocess.Popen(["sudo", "reboot"])
            return {"status": "ok", "command": command}

        if command == "start_stream":
            self.stream_should_run = True
            self.start_stream()
            return {"status": "ok", "command": command}

        if command == "stop_stream":
            self.stop_stream()
            return {"status": "ok", "command": command}

        if command == "reset_camera":
            self.stop_stream()
            video_device = self._cfg("video_device", "").strip()
            if not video_device:
                return {"status": "error", "detail": "No configured camera device"}
            if self._reset_usb_camera(video_device):
                return {"status": "ok", "command": command, "detail": f"Reset {video_device}"}
            return {"status": "error", "detail": f"Failed to reset {video_device}"}

        if command == "update_settings":
            if isinstance(command_payload, dict):
                to_store = {
                    str(k): str(v)
                    for k, v in command_payload.items()
                    if isinstance(k, str) and isinstance(v, (str, int, float, bool))
                }
                if to_store:
                    self.store.set_many(to_store)
            return {"status": "ok", "command": command, "payload": command_payload}

        if command == "unpair":
            self.stop_stream()
            self.store.set_many({
                "paired": "0",
                "pair_code": "",
                "pair_code_expires_at": "",
                "stream_status": "idle",
                "stream_detail": "",
            })
            self._current_stream_status = "idle"
            self._current_stream_detail = ""
            self._restart_requested = True  # exit WS + watchdog loops → re-register
            return {"status": "ok", "command": command}

        return {"status": "ignored", "detail": f"Unknown command: {command}"}

    async def stream_watchdog_loop(self) -> None:
        while not self.stop_requested and not self._restart_requested:
            if self.stream_should_run:
                if self.stream_process and self.stream_process.poll() is not None:
                    exit_code = self.stream_process.poll()
                    self.stream_process = None
                    detail = f"Stream process exited with code {exit_code}"
                    print(detail)
                    self._schedule_stream_retry(10, detail)

                if not self.stream_process:
                    self.start_stream()
                elif self.stream_process.poll() is None and self._current_stream_status == "starting":
                    # Process survived its first watchdog tick — it's live.
                    self._set_stream_state("streaming", self._current_stream_detail)
            await asyncio.sleep(2)

    async def run_ws_loop(self) -> None:
        device_id = self._cfg("device_id")
        ws_base = self._cfg("backend_ws").rstrip("/")
        device_secret = parse.quote(self._cfg("device_secret"), safe="")
        ws_url = f"{ws_base}/ws/device/{device_id}?role=device&device_secret={device_secret}"

        while not self.stop_requested and not self._restart_requested:
            try:
                async with websockets.connect(ws_url, ping_interval=20, ping_timeout=20) as ws:
                    while not self.stop_requested and not self._restart_requested:
                        try:
                            raw = await asyncio.wait_for(ws.recv(), timeout=1)
                        except TimeoutError:
                            continue
                        message = json.loads(raw)
                        if message.get("type") != "command":
                            continue
                        result = await self.handle_command(message)
                        await ws.send(json.dumps(result))
            except Exception as exc:
                print(f"websocket disconnected: {exc}")
                await asyncio.sleep(3)

    async def run(self) -> None:
        while not self.stop_requested:
            try:
                already_paired = False
                try:
                    registration = self.register_device()
                    print(
                        "Registered device",
                        registration["device_id"],
                        "pair_code=",
                        registration["pair_code"],
                        "expires_in=",
                        registration["expires_in"],
                    )
                except error.HTTPError as exc:
                    if exc.code == 409:
                        # Backend says already paired — confirm with status
                        # endpoint (which also writes paired=1 to SQLite).
                        print("Device already paired (409), checking status…")
                        already_paired = self.is_paired()
                        if not already_paired:
                            # Shouldn't happen, but back off and retry.
                            await asyncio.sleep(5)
                            continue
                    else:
                        raise

                if already_paired:
                    print("Device paired. Starting stream + websocket control")
                    self.stream_should_run = True
                    self.start_stream()
                    watchdog = asyncio.create_task(self.stream_watchdog_loop())
                    try:
                        await self.run_ws_loop()
                    finally:
                        watchdog.cancel()
                    if self._restart_requested:
                        self._restart_requested = False
                        self.stream_should_run = False
                    continue

                while not self.stop_requested:
                    if self.is_paired():
                        print("Device paired. Starting stream + websocket control")
                        self.stream_should_run = True
                        self.start_stream()
                        watchdog = asyncio.create_task(self.stream_watchdog_loop())
                        try:
                            await self.run_ws_loop()
                        finally:
                            watchdog.cancel()
                        if self._restart_requested:
                            self._restart_requested = False
                            self.stream_should_run = False
                        break
                    await asyncio.sleep(5)
            except error.HTTPError as exc:
                print(f"HTTP error: {exc.code} {exc.reason}")
                await asyncio.sleep(5)
            except Exception as exc:
                print(f"agent error: {exc}")
                await asyncio.sleep(5)

    def request_stop(self) -> None:
        self.stop_requested = True
        self.stop_stream()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="SBC device runtime agent")
    parser.add_argument(
        "--state-db",
        default="/var/lib/spektrum/device_state.db",
        help="Path to internal SQLite state database",
    )
    return parser.parse_args()


async def main() -> None:
    args = parse_args()
    agent = DeviceAgent(Path(args.state_db))

    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, agent.request_stop)

    await agent.run()


if __name__ == "__main__":
    asyncio.run(main())
