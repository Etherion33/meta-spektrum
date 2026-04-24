#!/usr/bin/env bash
set -euo pipefail

# First-boot runtime initialization for Spektrum SBC.
# All dependencies are pre-installed by prepare-image.sh during image build.
# This script only does runtime initialization: directories, state DB, service startup.
# Does NOT require internet connection.

MARKER_FILE="/var/lib/spektrum/.first_boot_done"
LOG_FILE="/var/log/spektrum-first-boot.log"
TAILSCALE_KEY_FILE="/etc/spektrum/tailscale-authkey"
TAILSCALE_ENROLL_SERVICE_NAME="spektrum-tailscale-enroll.service"

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

# Create runtime directories.
mkdir -p /var/lib/spektrum /etc/spektrum

# Disable legacy services if present.
for svc in "${LEGACY_SERVICES[@]}"; do
  if systemctl list-unit-files | grep -q "^${svc}"; then
    systemctl disable --now "${svc}" || true
  fi
done

# Enable required services and optional units if installed.
REQUIRED_SERVICES=(
  "spektrum-autonomous.service"
  "spektrum-device-info.service"
)
OPTIONAL_SERVICES=(
  "spektrum-oled-status.service"
)

for svc in "${REQUIRED_SERVICES[@]}"; do
  if systemctl list-unit-files | grep -q "^${svc}"; then
    systemctl enable "${svc}"
  else
    echo "[first_boot] WARNING: required service missing: ${svc}"
  fi
done

for svc in "${OPTIONAL_SERVICES[@]}"; do
  if systemctl list-unit-files | grep -q "^${svc}"; then
    systemctl enable "${svc}"
  fi
done

# Stage Tailscale auth key if provided.
if [[ -n "${SPEKTRUM_TAILSCALE_AUTHKEY:-}" ]]; then
  install -m 700 -d /etc/spektrum
  printf "%s\n" "${SPEKTRUM_TAILSCALE_AUTHKEY}" > "${TAILSCALE_KEY_FILE}"
  chmod 600 "${TAILSCALE_KEY_FILE}"
  echo "[first_boot] tailscale auth key staged at ${TAILSCALE_KEY_FILE}"
  systemctl enable "${TAILSCALE_ENROLL_SERVICE_NAME}"
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
db = sqlite3.connect("${STATE_DB}")
db.execute("CREATE TABLE IF NOT EXISTS state (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
db.execute("INSERT OR REPLACE INTO state (key, value) VALUES ('device_secret', ?)", ("${DEVICE_SECRET}",))
db.commit()
db.close()
print("[first_boot] device_secret written to state DB")
PYEOF
fi

# Start required services and optional units if installed.
for svc in "spektrum-device-info.service" "spektrum-autonomous.service"; do
  if systemctl list-unit-files | grep -q "^${svc}"; then
    systemctl start "${svc}"
  fi
done

if systemctl list-unit-files | grep -q "^spektrum-oled-status.service"; then
  systemctl start spektrum-oled-status.service
fi

if [[ -f "/etc/systemd/system/${TAILSCALE_ENROLL_SERVICE_NAME}" ]]; then
  systemctl restart tailscaled || true
  systemctl start "${TAILSCALE_ENROLL_SERVICE_NAME}" || true
fi

# Disable first-boot launcher service after success.
if [[ -n "${FIRST_BOOT_SERVICE_NAME:-}" ]]; then
  systemctl disable --now "${FIRST_BOOT_SERVICE_NAME}" || true
fi

touch "${MARKER_FILE}"
echo "[$(date -Is)] Spektrum first-boot initialization completed"
