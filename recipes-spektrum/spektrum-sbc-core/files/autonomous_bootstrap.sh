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
INFO_SERVICE_PATHS=(
  "/etc/systemd/system/${INFO_SERVICE_NAME}"
  "/usr/lib/systemd/system/${INFO_SERVICE_NAME}"
)

has_info_service_unit() {
  local unit_path
  for unit_path in "${INFO_SERVICE_PATHS[@]}"; do
    if [[ -f "${unit_path}" ]]; then
      return 0
    fi
  done
  return 1
}

is_non_negative_int() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

ap_is_ready() {
  if ! ip link show "${WLAN_IFACE}" >/dev/null 2>&1; then
    return 1
  fi

  ip -4 -o addr show dev "${WLAN_IFACE}" | grep -q '192\.168\.4\.1/24'
}

ensure_ap_ready() {
  if ap_is_ready; then
    return 0
  fi

  log "AP is not ready on ${WLAN_IFACE}; re-running hotspot setup"
  bash "${SETUP_AP_SCRIPT}" "${WLAN_IFACE}" "${SHORT_ID}" "${AP_PASSWORD}"
}

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

has_wifi_credentials() {
  local ssid
  ssid="$(read_state wifi_ssid)"
  [[ -n "${ssid}" ]]
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
  local mode="${1:-initial}"
  local timeout_seconds="${2:-0}"
  local healthcheck_interval
  local before_stamp current_stamp elapsed
  elapsed=0

  healthcheck_interval="${SPEKTRUM_AP_HEALTHCHECK_INTERVAL_SECONDS:-5}"

  if ! is_non_negative_int "${timeout_seconds}"; then
    timeout_seconds=0
  fi
  if ! is_non_negative_int "${healthcheck_interval}" || [[ "${healthcheck_interval}" -lt 1 ]]; then
    healthcheck_interval=5
  fi

  before_stamp="$(read_state last_configured_at)"

  if [[ "${mode}" == "recovery" ]]; then
    log "Starting temporary recovery AP mode"
  else
    log "Starting AP provisioning mode"
  fi

  bash "${SETUP_AP_SCRIPT}" "${WLAN_IFACE}" "${SHORT_ID}" "${AP_PASSWORD}"

  if has_info_service_unit; then
    if ! systemctl is-active --quiet "${INFO_SERVICE_NAME}"; then
      log "Starting always-on device info service"
      systemctl start "${INFO_SERVICE_NAME}" || true
    fi

    if config_complete; then
      log "Waiting for updated configuration from device portal"
      while true; do
        ensure_ap_ready || true
        sleep "${healthcheck_interval}"
        elapsed=$((elapsed + healthcheck_interval))
        current_stamp="$(read_state last_configured_at)"
        if [[ -n "${current_stamp}" && "${current_stamp}" != "${before_stamp}" ]]; then
          log "Configuration updated from portal"
          break
        fi

        if [[ "${timeout_seconds}" -gt 0 && "${elapsed}" -ge "${timeout_seconds}" ]]; then
          log "Recovery AP timeout reached (${timeout_seconds}s), returning to STA retries"
          return 0
        fi
      done
    else
      log "Waiting for initial configuration from device portal"
      while ! config_complete; do
        ensure_ap_ready || true
        sleep "${healthcheck_interval}"
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
  local sta_failures recovery_ap_enabled recovery_fail_threshold recovery_ap_window

  recovery_ap_enabled="${SPEKTRUM_ENABLE_RECOVERY_AP:-1}"
  recovery_fail_threshold="${SPEKTRUM_STA_FAIL_THRESHOLD:-6}"
  recovery_ap_window="${SPEKTRUM_RECOVERY_AP_WINDOW_SECONDS:-180}"

  if ! is_non_negative_int "${recovery_fail_threshold}"; then
    recovery_fail_threshold=6
  fi
  if ! is_non_negative_int "${recovery_ap_window}"; then
    recovery_ap_window=180
  fi

  sta_failures=0

  if has_info_service_unit; then
    if ! systemctl is-active --quiet "${INFO_SERVICE_NAME}"; then
      log "Starting always-on device info service"
      systemctl start "${INFO_SERVICE_NAME}" || true
    fi
  fi

  while true; do
    if have_state && has_wifi_credentials; then
      if try_join_sta; then
        sta_failures=0
        if config_complete; then
          start_agent
        fi
        log "STA connected; backend/device configuration incomplete, waiting for portal configuration updates"
        sleep 5
        continue
      fi

      sta_failures=$((sta_failures + 1))
      if [[ "${recovery_ap_enabled}" == "1" && "${sta_failures}" -ge "${recovery_fail_threshold}" ]]; then
        log "STA failed ${sta_failures} times; opening temporary recovery AP for ${recovery_ap_window}s without resetting state"
        start_provisioning recovery "${recovery_ap_window}"
        sta_failures=0
        sleep 2
        continue
      fi

      log "Wi-Fi credentials exist; transient failure ${sta_failures}/${recovery_fail_threshold}, retrying STA (AP remains disabled)"
      sleep 5
      continue
    else
      log "No Wi-Fi credentials found, entering provisioning AP"
    fi

    start_provisioning initial 0
    sleep 2
  done
}

main_loop
