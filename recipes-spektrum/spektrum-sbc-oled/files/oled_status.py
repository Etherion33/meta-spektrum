#!/usr/bin/env python3
"""SSD1306 OLED status panel for Spektrum SBC devices.

Shows current IP and runtime status by reading the local state DB.
Designed for 0.91" 128x32 displays on I2C.
"""

from __future__ import annotations

import argparse
import ipaddress
import socket
import subprocess
import sys
import time
from pathlib import Path

from state_store import StateStore

try:
    from luma.core.interface.serial import i2c
    from luma.oled.device import ssd1306
    from PIL import Image, ImageDraw, ImageFont
except Exception as exc:  # pragma: no cover
    print(
        "Missing OLED dependencies. Install with: "
        "python3 -m pip install luma.oled pillow",
        file=sys.stderr,
    )
    raise SystemExit(str(exc))


def detect_ip(preferred_iface: str = "wlan0") -> tuple[str, str]:
    """Best-effort local IPv4 detection with interface preference.

    In AP mode we prefer the Wi-Fi interface IP (typically 192.168.4.1)
    so OLED always shows the portal address users need.
    """
    iface = (preferred_iface or "").strip()
    if iface:
        try:
            output = subprocess.check_output(
                ["ip", "-4", "addr", "show", "dev", iface],
                text=True,
                stderr=subprocess.DEVNULL,
            )
            for line in output.splitlines():
                line = line.strip()
                if not line.startswith("inet "):
                    continue
                addr = line.split()[1].split("/", 1)[0]
                if addr:
                    return (iface, addr)
        except Exception:
            pass

    def is_tailscale_like(ip_text: str) -> bool:
        try:
            ip_obj = ipaddress.ip_address(ip_text)
        except ValueError:
            return True
        return ip_obj in ipaddress.ip_network("100.64.0.0/10")

    try:
        output = subprocess.check_output(
            ["ip", "-4", "-o", "addr", "show", "scope", "global"],
            text=True,
            stderr=subprocess.DEVNULL,
        )
            candidates: list[tuple[int, str, str]] = []
        for line in output.splitlines():
            parts = line.split()
            if len(parts) < 4:
                continue
            iface_name = parts[1]
            addr = parts[3].split("/", 1)[0]
            if not addr or is_tailscale_like(addr):
                continue
            if iface_name == iface:
                priority = 0
            elif iface_name.startswith(("wlan", "wl")):
                priority = 1
            elif iface_name.startswith(("eth", "en")):
                priority = 2
            elif iface_name.startswith(("tailscale", "tun", "wg", "docker", "veth", "br-", "virbr")):
                continue
            else:
                priority = 3
            candidates.append((priority, iface_name, addr))

        if candidates:
            candidates.sort(key=lambda item: item[0])
            _, iface_name, addr = candidates[0]
            return (iface_name, addr)
    except Exception:
        pass

    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.connect(("8.8.8.8", 80))
            ip = sock.getsockname()[0]
            if ip and not is_tailscale_like(ip):
                return ("route", ip)
    except Exception:
        pass

    try:
        output = subprocess.check_output(["hostname", "-I"], text=True).strip()
        if output:
            for candidate in output.split():
                if not is_tailscale_like(candidate):
                    return ("host", candidate)
    except Exception:
        pass

    return ("-", "-")


def summarize_status(state: dict[str, str]) -> str:
    paired = state.get("paired", "0") == "1"
    stream = (state.get("stream_status", "idle") or "idle").strip().lower()

    if paired:
        pair_label = "PAIRED"
    elif state.get("wifi_ssid") and state.get("backend_http"):
        pair_label = "PAIR"
    else:
        pair_label = "PROVISION"

    stream = stream.upper() if stream else "IDLE"
    return f"{pair_label}|{stream}"


def load_fonts() -> tuple[ImageFont.ImageFont, ImageFont.ImageFont]:
    """Load readable fonts with fallback for minimal systems."""
    candidates = [
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
    ]

    for path in candidates:
        try:
            main_font = ImageFont.truetype(path, 12)
            small_font = ImageFont.truetype(path, 9)
            return main_font, small_font
        except Exception:
            continue

    fallback = ImageFont.load_default()
    return fallback, fallback


def _shorten(text: str, limit: int) -> str:
    if len(text) <= limit:
        return text
    if limit <= 1:
        return text[:limit]
    return text[: limit - 1] + "~"


def read_uptime() -> str:
    try:
        with open("/proc/uptime", "r", encoding="utf-8") as handle:
            total_seconds = int(float(handle.read().split()[0]))
    except Exception:
        return "-"

    days, rem = divmod(total_seconds, 86400)
    hours, rem = divmod(rem, 3600)
    minutes, _ = divmod(rem, 60)
    if days > 0:
        return f"{days}d {hours}h"
    return f"{hours:02d}h {minutes:02d}m"


def mock_battery_percent(device_id: str) -> int:
    """Deterministic mock battery value for UI until real telemetry is wired."""
    seed = 0
    for ch in device_id:
        seed = (seed * 31 + ord(ch)) % 997
    return 35 + (seed % 61)


def render_dashboard(
    device,
    *,
    iface: str,
    ip: str,
    status_text: str,
    short_id: str,
    pair_code: str,
    battery_percent: int,
    main_font,
    small_font,
    offset_x: int = 0,
    offset_y: int = 0,
) -> None:
    image = Image.new("1", (device.width, device.height))
    draw = ImageDraw.Draw(image)
    width = device.width
    height = device.height

    def text_size(text: str, font) -> tuple[int, int]:
        left, top, right, bottom = draw.textbbox((0, 0), text, font=font)
        return right - left, bottom - top

    _, small_h = text_size("Ag", small_font)
    _, main_h = text_size("Ag", main_font)

    # Header bar (uses inverse colors for at-a-glance status).
    header_h = min(10, max(8, small_h + 2))
    draw.rectangle((0 + offset_x, 0 + offset_y, width - 1 + offset_x, header_h - 1 + offset_y), outline=255, fill=255)

    mode, _, stream = status_text.partition("|")
    mode_text = _shorten(mode, 11)
    stream_text = _shorten(stream, 9)
    battery_text = f"B{battery_percent:02d}%"

    header_text_y = max(0, (header_h - small_h) // 2 - 1)
    mode_w, _ = text_size(mode_text, small_font)
    battery_w, _ = text_size(battery_text, small_font)
    battery_x = width - battery_w - 2 + offset_x

    available_stream_w = battery_x - (2 + offset_x + mode_w + 4)
    while stream_text and text_size(stream_text, small_font)[0] > available_stream_w:
        stream_text = _shorten(stream_text, max(1, len(stream_text) - 1))

    draw.text((2 + offset_x, header_text_y + offset_y), mode_text, font=small_font, fill=0)
    right_w, _ = text_size(stream_text, small_font)
    draw.text((battery_x - right_w - 3, header_text_y + offset_y), stream_text, font=small_font, fill=0)
    draw.text((battery_x, header_text_y + offset_y), battery_text, font=small_font, fill=0)

    # Main row and footer are placed from measured font heights to avoid clipping.
    main_y = header_h + 1
    footer_y = height - small_h - 1
    use_compact_ip = footer_y <= main_y + main_h

    ip_text = ip if ip else "-"
    iface_text = _shorten((iface or "-").strip(), 6)
    ip_line = f"{iface_text} {ip_text}" if iface_text and iface_text != "-" else ip_text
    if use_compact_ip:
        draw.text((2 + offset_x, main_y + offset_y), "IP", font=small_font, fill=255)
        draw.text((16 + offset_x, main_y + offset_y), _shorten(ip_line, 18), font=small_font, fill=255)
    else:
        value_y = max(main_y - 1, main_y + (small_h - main_h) // 2)
        draw.text((2 + offset_x, main_y + 1 + offset_y), "IP", font=small_font, fill=255)
        draw.text((18 + offset_x, value_y + offset_y), _shorten(ip_line, 17), font=main_font, fill=255)

    # Footer row: ID and pairing code.
    footer = f"ID {_shorten(short_id or '-', 8)}"
    code_text = pair_code.strip() if pair_code.strip() else "-"
    code_text = _shorten(code_text, 8)
    draw.text((2 + offset_x, footer_y + offset_y), footer, font=small_font, fill=255)

    code_label = f"CODE {code_text}"
    code_w, _ = text_size(code_label, small_font)
    draw.text((width - code_w - 2 + offset_x, footer_y + offset_y), code_label, font=small_font, fill=255)

    device.display(image)


def render_secondary_page(
    device,
    *,
    ssid: str,
    uptime: str,
    battery_percent: int,
    small_font,
    offset_x: int = 0,
    offset_y: int = 0,
) -> None:
    image = Image.new("1", (device.width, device.height))
    draw = ImageDraw.Draw(image)

    def text_size(text: str, font) -> tuple[int, int]:
        left, top, right, bottom = draw.textbbox((0, 0), text, font=font)
        return right - left, bottom - top

    width = device.width
    _, small_h = text_size("Ag", small_font)
    header_h = min(10, max(8, small_h + 2))

    draw.rectangle((0 + offset_x, 0 + offset_y, width - 1 + offset_x, header_h - 1 + offset_y), outline=255, fill=255)
    title = "NETWORK"
    battery_text = f"B{battery_percent:02d}%"
    battery_w, _ = text_size(battery_text, small_font)
    title_x = 2
    title_y = max(0, (header_h - small_h) // 2 - 1)
    draw.text((title_x + offset_x, title_y + offset_y), title, font=small_font, fill=0)
    draw.text((width - battery_w - 2 + offset_x, title_y + offset_y), battery_text, font=small_font, fill=0)

    body_y = header_h + 1
    row_gap = max(1, (device.height - body_y - (small_h * 2)) // 2)
    up = uptime.strip() if uptime.strip() else "-"
    lines = [
        f"SSID {_shorten(ssid or '-', 16)}",
        f"UPTIME {_shorten(up, 14)}",
    ]

    y = body_y
    for line in lines:
        draw.text((2 + offset_x, y + offset_y), line, font=small_font, fill=255)
        y += small_h + row_gap

    device.display(image)


def main() -> int:
    parser = argparse.ArgumentParser(description="Render device status on SSD1306 OLED")
    parser.add_argument("--state-db", type=Path, default=Path("/var/lib/spektrum/device_state.db"))
    parser.add_argument("--i2c-port", type=int, default=3)
    parser.add_argument("--i2c-address", default="0x3C")
    parser.add_argument("--width", type=int, default=128)
    parser.add_argument("--height", type=int, default=32)
    parser.add_argument("--interval", type=float, default=2.0)
    parser.add_argument("--page-seconds", type=float, default=4.0)
    parser.add_argument("--display-retry-seconds", type=float, default=30.0)
    parser.add_argument(
        "--rotate",
        type=int,
        choices=(0, 1, 2, 3),
        default=0,
        help="Display rotation in 90 degree steps: 0=0deg, 1=90deg, 2=180deg, 3=270deg",
    )
    args = parser.parse_args()

    store = StateStore(args.state_db)

    def init_display():
        serial = i2c(port=args.i2c_port, address=int(args.i2c_address, 16))
        return ssd1306(serial, width=args.width, height=args.height, rotate=args.rotate)

    device = None
    main_font, small_font = load_fonts()
    cached_ip = "-"
    cached_iface = "-"
    next_ip_refresh_at = 0.0
    last_render_key: tuple | None = None
    render_error_count = 0
    next_display_retry_at = 0.0
    display_missing_logged = False
    # Subtle pixel shift to reduce OLED burn-in over long runtimes.
    burn_in_offsets = [(0, 0), (1, 0), (0, 1), (-1, 0), (0, -1)]
    burn_in_step = 0
    burn_in_next_at = time.monotonic() + 60.0

    while True:
        now_monotonic = time.monotonic()

        if device is None and now_monotonic >= next_display_retry_at:
            try:
                device = init_display()
                last_render_key = None
                render_error_count = 0
                display_missing_logged = False
                print("oled display initialized", file=sys.stderr)
            except Exception as exc:
                if not display_missing_logged:
                    print(
                        f"oled display not detected ({exc}); retrying in {args.display_retry_seconds:.0f}s",
                        file=sys.stderr,
                    )
                    display_missing_logged = True
                next_display_retry_at = now_monotonic + max(args.display_retry_seconds, 5.0)

        if device is None:
            time.sleep(max(args.interval, 1.0))
            continue

        state = store.as_dict()
        device_id = state.get("device_id", "-")
        short_id = device_id[:8] if device_id and device_id != "-" else "-"
        battery = mock_battery_percent(device_id)
        if now_monotonic >= next_ip_refresh_at:
            preferred_iface = state.get("wifi_interface", "wlan0")
            cached_iface, cached_ip = detect_ip(preferred_iface)
            next_ip_refresh_at = now_monotonic + 8.0
        iface = cached_iface
        ip = cached_ip
        status = summarize_status(state)

        pair_code = state.get("pair_code", "").strip()
        ssid = state.get("wifi_ssid", "").strip()
        uptime = read_uptime()
        page_seconds = max(args.page_seconds, 0.5)
        page_index = int(now_monotonic / page_seconds) % 2

        if now_monotonic >= burn_in_next_at:
            burn_in_step = (burn_in_step + 1) % len(burn_in_offsets)
            burn_in_next_at = now_monotonic + 60.0
        offset_x, offset_y = burn_in_offsets[burn_in_step]

        if page_index == 0:
            render_key = (
                0,
                iface,
                ip,
                status,
                short_id,
                pair_code,
                battery,
                offset_x,
                offset_y,
            )
        else:
            render_key = (
                1,
                ssid,
                uptime,
                battery,
                offset_x,
                offset_y,
            )

        if render_key == last_render_key:
            time.sleep(max(args.interval, 0.5))
            continue

        try:
            if page_index == 0:
                render_dashboard(
                    device,
                    iface=iface,
                    ip=ip,
                    status_text=status,
                    short_id=short_id,
                    pair_code=pair_code,
                    battery_percent=battery,
                    main_font=main_font,
                    small_font=small_font,
                    offset_x=offset_x,
                    offset_y=offset_y,
                )
            else:
                render_secondary_page(
                    device,
                    ssid=ssid,
                    uptime=uptime,
                    battery_percent=battery,
                    small_font=small_font,
                    offset_x=offset_x,
                    offset_y=offset_y,
                )
            last_render_key = render_key
            render_error_count = 0
        except Exception as exc:
            print(f"oled render error: {exc}", file=sys.stderr)
            render_error_count += 1
            if render_error_count >= 3:
                try:
                    device = init_display()
                    render_error_count = 0
                    last_render_key = None
                    print("oled display reinitialized", file=sys.stderr)
                except Exception as reinit_exc:
                    print(f"oled reinit failed: {reinit_exc}", file=sys.stderr)
                    device = None
                    next_display_retry_at = time.monotonic() + max(args.display_retry_seconds, 5.0)

        time.sleep(max(args.interval, 0.5))


if __name__ == "__main__":
    raise SystemExit(main())
