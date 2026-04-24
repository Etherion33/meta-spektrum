#!/usr/bin/env bash
set -euo pipefail

STATE_DB="${1:-/var/lib/spektrum/device_state.db}"
WLAN_IFACE="${2:-wlan0}"
SHORT_ID="$(cat /etc/machine-id | cut -c1-6)"
AP_PASSWORD="${SPEKTRUM_AP_PASSWORD:-device12345}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_AP_SCRIPT="${SCRIPT_DIR}/setup_hotspot.sh"
PROVISIONING_SCRIPT="${SCRIPT_DIR}/provisioning_server.py"
AGENT_SCRIPT="${SCRIPT_DIR}/device_agent.py"
SWITCH_STA_SCRIPT="${SCRIPT_DIR}/switch_to_sta.sh"
INFO_SERVICE_NAME="spektrum-device-info.service"

log() {
  echo "[$(date -Is)] $*"
}

have_state() {
  [[ -f "${STATE_DB}" ]]
}

read_state() {
  local key="$1"
  python3 - "$STATE_DB" "$key" <<'PY'
import sqlite3
import sys
from pathlib import Path

db = Path(sys.argv[1])
key = sys.argv[2]
if not db.exists():
    print("")
    raise SystemExit(0)

try:
    conn = sqlite3.connect(db)
    row = conn.execute("SELECT value FROM state WHERE key = ?", (key,)).fetchone()
    conn.close()
except Exception:
    print("")
    raise SystemExit(0)

if not row or row[0] is None:
    print("")
else:
    print(str(row[0]))
PY
}

config_complete() {
  local backend_http backend_ws device_secret ssid
  backend_http="$(read_state backend_http)"
  backend_ws="$(read_state backend_ws)"
  device_secret="$(read_state device_secret)"
  ssid="$(read_state wifi_ssid)"

  [[ -n "${backend_http}" && -n "${backend_ws}" && -n "${device_secret}" && -n "${ssid}" ]]
}

backend_reachable() {
  local backend_http
  local wifi_only
  local check_iface
  backend_http="$(read_state backend_http)"
  [[ -n "${backend_http}" ]] || return 1

  wifi_only="${SPEKTRUM_BACKEND_CHECK_VIA_WIFI_ONLY:-1}"
  check_iface="${SPEKTRUM_BACKEND_CHECK_INTERFACE:-${WLAN_IFACE}}"

  if [[ "${wifi_only}" == "1" && -n "${check_iface}" ]]; then
    ip -4 -o addr show dev "${check_iface}" scope global | grep -q ' inet ' || return 1
    curl -fsS --connect-timeout 3 --max-time 5 --interface "${check_iface}" "${backend_http%/}/api/v1/utils/health-check/" >/dev/null
    return 0
  fi

  curl -fsS --connect-timeout 3 --max-time 5 "${backend_http%/}/api/v1/utils/health-check/" >/dev/null
}

try_join_sta() {
  local ssid password
  ssid="$(read_state wifi_ssid)"
  password="$(read_state wifi_password)"
  [[ -n "${ssid}" ]] || return 1

  log "Trying STA connection on ${WLAN_IFACE} to SSID ${ssid}"
  bash "${SWITCH_STA_SCRIPT}" "${WLAN_IFACE}" "${ssid}" "${password}"

  for _ in $(seq 1 20); do
    if backend_reachable; then
      return 0
    fi
    sleep 2
  done
  return 1
}

start_provisioning() {
  local before_stamp current_stamp
  before_stamp="$(read_state last_configured_at)"

  log "Starting AP provisioning mode"
  bash "${SETUP_AP_SCRIPT}" "${WLAN_IFACE}" "${SHORT_ID}" "${AP_PASSWORD}"

  if systemctl list-unit-files | grep -q "^${INFO_SERVICE_NAME}"; then
    if ! systemctl is-active --quiet "${INFO_SERVICE_NAME}"; then
      log "Starting always-on device info service"
      systemctl start "${INFO_SERVICE_NAME}" || true
    fi

    if config_complete; then
      log "Waiting for updated configuration from device portal"
      while true; do
        sleep 2
        current_stamp="$(read_state last_configured_at)"
        if [[ -n "${current_stamp}" && "${current_stamp}" != "${before_stamp}" ]]; then
          break
        fi
      done
    else
      log "Waiting for initial configuration from device portal"
      while ! config_complete; do
        sleep 2
      done
    fi
  else
    log "Info service missing, using legacy bootstrap-managed provisioning server"
    /usr/bin/python3 "${PROVISIONING_SCRIPT}" --exit-after-configure --state-db "${STATE_DB}"
  fi
}

start_agent() {
  log "Starting autonomous device agent"
  exec /usr/bin/python3 "${AGENT_SCRIPT}" --state-db "${STATE_DB}"
}

main_loop() {
  if systemctl list-unit-files | grep -q "^${INFO_SERVICE_NAME}"; then
    if ! systemctl is-active --quiet "${INFO_SERVICE_NAME}"; then
      log "Starting always-on device info service"
      systemctl start "${INFO_SERVICE_NAME}" || true
    fi
  fi

  while true; do
    if have_state && config_complete; then
      if try_join_sta; then
        start_agent
      fi
      log "Configured network not reachable, falling back to provisioning AP"
    else
      log "No complete config found, entering provisioning AP"
    fi

    start_provisioning
    sleep 2
  done
}

main_loop
