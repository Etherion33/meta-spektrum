#!/usr/bin/env bash
set -euo pipefail

MARKER_FILE="/var/lib/spektrum/.tailscale_enrolled"
KEY_FILE="/etc/spektrum/tailscale-authkey"

if [[ -f "${MARKER_FILE}" ]]; then
  exit 0
fi

if ! command -v tailscale >/dev/null 2>&1; then
  echo "[tailscale-enroll] tailscale binary not found" >&2
  exit 1
fi

if ! systemctl is-active --quiet tailscaled; then
  systemctl restart tailscaled
fi

if [[ "${SPEKTRUM_TAILSCALE_WAIT_FOR_ROUTE:-1}" == "1" ]]; then
  MAX_WAIT_SECONDS="${SPEKTRUM_TAILSCALE_ROUTE_WAIT_SECONDS:-120}"
  DEADLINE=$((SECONDS + MAX_WAIT_SECONDS))
  while (( SECONDS < DEADLINE )); do
    if ip route show default 2>/dev/null | grep -q '^default '; then
      break
    fi
    sleep 2
  done
fi

AUTH_KEY="${SPEKTRUM_TAILSCALE_AUTHKEY:-}"
if [[ -z "${AUTH_KEY}" && -f "${KEY_FILE}" ]]; then
  AUTH_KEY="$(tr -d '\r\n' < "${KEY_FILE}")"
fi

if [[ -z "${AUTH_KEY}" ]]; then
  echo "[tailscale-enroll] no auth key configured" >&2
  exit 1
fi

HOST_PREFIX="${SPEKTRUM_TAILSCALE_HOSTNAME_PREFIX:-spektrum-cam}"
MACHINE_ID="$(cat /etc/machine-id 2>/dev/null | cut -c1-6 || true)"
if [[ -z "${MACHINE_ID}" ]]; then
  MACHINE_ID="$(hostname | cut -c1-6)"
fi
TS_HOSTNAME="${HOST_PREFIX}-${MACHINE_ID}"

ARGS=(
  --authkey "${AUTH_KEY}"
  --hostname "${TS_HOSTNAME}"
)

if [[ -n "${SPEKTRUM_TAILSCALE_ADVERTISE_TAGS:-}" ]]; then
  ARGS+=(--advertise-tags "${SPEKTRUM_TAILSCALE_ADVERTISE_TAGS}")
fi

# tailscale up succeeds only when network/control plane is reachable.
# systemd restarts this one-shot service until it succeeds.
tailscale up "${ARGS[@]}"

touch "${MARKER_FILE}"
chmod 600 "${MARKER_FILE}" || true

# Remove key after successful enrollment to reduce exposure.
rm -f "${KEY_FILE}"

echo "[tailscale-enroll] enrolled as ${TS_HOSTNAME}"
