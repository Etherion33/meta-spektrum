#!/usr/bin/env bash
set -euo pipefail

WLAN_IFACE="${1:-wlan0}"
SSID="${2:?SSID is required}"
PASSWORD="${3:-}"

systemctl stop hostapd dnsmasq || true
ip addr flush dev "${WLAN_IFACE}" || true

if command -v nmcli >/dev/null 2>&1; then
  nmcli dev set "${WLAN_IFACE}" managed yes || true
  nmcli con delete "spektrum-${SSID}" >/dev/null 2>&1 || true
  if [[ -n "${PASSWORD}" ]]; then
    nmcli dev wifi connect "${SSID}" password "${PASSWORD}" ifname "${WLAN_IFACE}" name "spektrum-${SSID}"
  else
    nmcli dev wifi connect "${SSID}" ifname "${WLAN_IFACE}" name "spektrum-${SSID}"
  fi
else
  cat >/etc/wpa_supplicant/wpa_supplicant-${WLAN_IFACE}.conf <<EOF
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=US

network={
  ssid="${SSID}"
  psk="${PASSWORD}"
}
EOF
  wpa_supplicant -B -i "${WLAN_IFACE}" -c "/etc/wpa_supplicant/wpa_supplicant-${WLAN_IFACE}.conf"
  dhclient "${WLAN_IFACE}"
fi

echo "Switched ${WLAN_IFACE} to STA mode"
