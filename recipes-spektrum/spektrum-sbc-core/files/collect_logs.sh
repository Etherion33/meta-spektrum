#!/usr/bin/env bash
set -euo pipefail

OUT_DIR="${1:-/var/lib/spektrum/logs}"
STATE_DB="${2:-/var/lib/spektrum/device_state.db}"
TS="$(date +%Y%m%d-%H%M%S)"
WORK_DIR="/tmp/spektrum-logbundle-${TS}"
BUNDLE_PATH="${OUT_DIR}/spektrum-logs-${TS}.tar.gz"

mkdir -p "${OUT_DIR}" "${WORK_DIR}"

safe_cmd() {
  local out="$1"
  shift
  if "$@" >"${WORK_DIR}/${out}" 2>&1; then
    :
  else
    echo "command failed: $*" >"${WORK_DIR}/${out}"
  fi
}

safe_cmd os-release cat /etc/os-release
safe_cmd uname uname -a
safe_cmd uptime uptime
safe_cmd disk df -h
safe_cmd memory free -h
safe_cmd ip-addr ip addr
safe_cmd ip-route ip route
safe_cmd nmcli-dev nmcli device status
safe_cmd nmcli-conn nmcli connection show
safe_cmd lsusb lsusb
safe_cmd dmesg-tail dmesg | tail -n 400
safe_cmd journal-autonomous journalctl -u spektrum-autonomous.service -n 600 --no-pager
safe_cmd journal-network journalctl -u NetworkManager -n 400 --no-pager
safe_cmd journal-hostapd journalctl -u hostapd -n 200 --no-pager
safe_cmd journal-dnsmasq journalctl -u dnsmasq -n 200 --no-pager

if command -v v4l2-ctl >/dev/null 2>&1; then
  safe_cmd v4l2-devices v4l2-ctl --list-devices
  safe_cmd v4l2-all-video0 v4l2-ctl --all -d /dev/video0
  safe_cmd v4l2-all-video1 v4l2-ctl --all -d /dev/video1
fi

python3 - "$STATE_DB" "${WORK_DIR}/state-redacted.json" <<'PY'
import json
import sqlite3
import sys
from pathlib import Path

db = Path(sys.argv[1])
out = Path(sys.argv[2])
redact = {"wifi_password", "device_secret"}
state = {}
if db.exists():
    try:
        conn = sqlite3.connect(db)
        for key, value in conn.execute("SELECT key, value FROM state"):
            if key in redact:
                state[key] = "<redacted>"
            else:
                state[key] = value
        conn.close()
    except Exception as exc:
        state = {"error": str(exc)}
else:
    state = {"error": f"state db not found: {db}"}

out.write_text(json.dumps(state, indent=2), encoding="utf-8")
PY

tar -C "${WORK_DIR}" -czf "${BUNDLE_PATH}" .
rm -rf "${WORK_DIR}"

echo "${BUNDLE_PATH}"
