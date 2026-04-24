#!/usr/bin/env bash
set -euo pipefail

# First-boot runtime initialization for Spektrum SBC.
# This script keeps only true first-boot state initialization.
# Service enablement and restart policy belong to recipe/systemd metadata.

MARKER_FILE="/var/lib/spektrum/.first_boot_done"
LOG_FILE="/var/log/spektrum-first-boot.log"
TAILSCALE_KEY_FILE="/etc/spektrum/tailscale-authkey"

# Services from legacy GST_APP that should not run on new images.
LEGACY_SERVICES=(
  "gst_cam_stream.service"
  "gst_cam_stream"
)

exec > >(tee -a "${LOG_FILE}") 2>&1

echo "[$(date -Is)] Spektrum first-boot initialization starting"

if [[ "${EUID}" -ne 0 ]]; then
  echo "This script must run as root"
  exit 1
fi

if [[ -f "${MARKER_FILE}" ]]; then
  echo "Marker exists (${MARKER_FILE}), initialization already completed. Exiting."
  exit 0
fi

# Disable legacy services if present.
for svc in "${LEGACY_SERVICES[@]}"; do
  if systemctl list-unit-files | grep -q "^${svc}"; then
    systemctl disable --now "${svc}" || true
  fi
done

# Stage Tailscale auth key if provided.
if [[ -n "${SPEKTRUM_TAILSCALE_AUTHKEY:-}" ]]; then
  install -m 700 -d /etc/spektrum
  printf "%s\n" "${SPEKTRUM_TAILSCALE_AUTHKEY}" > "${TAILSCALE_KEY_FILE}"
  chmod 600 "${TAILSCALE_KEY_FILE}"
  echo "[first_boot] tailscale auth key staged at ${TAILSCALE_KEY_FILE}"
fi

# Seed the device secret into the state DB.
# Set SPEKTRUM_DEVICE_SECRET before running this script.
# WARNING: Do not use a plaintext default in production.
STATE_DB="/var/lib/spektrum/device_state.db"
DEVICE_SECRET="${SPEKTRUM_DEVICE_SECRET:-}"
if [[ -z "${DEVICE_SECRET}" ]]; then
  echo "WARNING: SPEKTRUM_DEVICE_SECRET not set. State DB will be seeded with empty value."
  echo "Set SPEKTRUM_DEVICE_SECRET env var before running this script to initialize properly."
else
  python3 - <<PYEOF
import sqlite3
from pathlib import Path

Path("${STATE_DB}").parent.mkdir(parents=True, exist_ok=True)
db = sqlite3.connect("${STATE_DB}")
db.execute("CREATE TABLE IF NOT EXISTS state (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
db.execute("INSERT OR REPLACE INTO state (key, value) VALUES ('device_secret', ?)", ("${DEVICE_SECRET}",))
db.commit()
db.close()
print("[first_boot] device_secret written to state DB")
PYEOF
fi

# Disable first-boot launcher service after success.
if [[ -n "${FIRST_BOOT_SERVICE_NAME:-}" ]]; then
  systemctl disable --now "${FIRST_BOOT_SERVICE_NAME}" || true
fi

touch "${MARKER_FILE}"
echo "[$(date -Is)] Spektrum first-boot initialization completed"
