#!/usr/bin/env bash
set -euo pipefail

WLAN_IFACE="${1:-wlan0}"
SHORT_ID="${2:-$(cat /etc/machine-id | cut -c1-6)}"
AP_PASSWORD="${3:-device12345}"
COUNTRY_CODE="${COUNTRY_CODE:-US}"

if [[ ${#AP_PASSWORD} -lt 8 ]]; then
  echo "AP password must be at least 8 characters" >&2
  exit 1
fi

SSID="Device-${SHORT_ID}"

cat >/etc/hostapd/hostapd.conf <<EOF
interface=${WLAN_IFACE}
driver=nl80211
ssid=${SSID}
hw_mode=g
channel=6
country_code=${COUNTRY_CODE}
ieee80211d=1
wmm_enabled=1
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=${AP_PASSWORD}
wpa_key_mgmt=WPA-PSK
wpa_pairwise=CCMP
rsn_pairwise=CCMP
EOF

cat >/etc/dnsmasq.d/spektrum-ap.conf <<EOF
interface=${WLAN_IFACE}
bind-interfaces
except-interface=lo
dhcp-range=192.168.4.10,192.168.4.200,255.255.255.0,12h
dhcp-authoritative
address=/#/192.168.4.1
EOF

sed -i 's|^#\?DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd || true

if command -v nmcli >/dev/null 2>&1; then
  nmcli radio wifi on || true
  nmcli device disconnect "${WLAN_IFACE}" || true
  nmcli dev set "${WLAN_IFACE}" managed no || true
fi

if command -v rfkill >/dev/null 2>&1; then
  rfkill unblock wlan || true
  rfkill unblock wifi || true
fi

for _ in $(seq 1 10); do
  if ip link show "${WLAN_IFACE}" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! ip link show "${WLAN_IFACE}" >/dev/null 2>&1; then
  echo "Wi-Fi interface ${WLAN_IFACE} not found" >&2
  exit 1
fi

systemctl stop hostapd dnsmasq || true

ip link set "${WLAN_IFACE}" down || true
ip addr flush dev "${WLAN_IFACE}" || true
ip addr add 192.168.4.1/24 dev "${WLAN_IFACE}"
ip link set "${WLAN_IFACE}" up

systemctl unmask hostapd
systemctl enable hostapd dnsmasq
systemctl restart dnsmasq
systemctl restart hostapd

if ! systemctl is-active --quiet dnsmasq; then
  echo "dnsmasq failed to start" >&2
  journalctl -u dnsmasq -n 40 --no-pager || true
  exit 1
fi

if ! systemctl is-active --quiet hostapd; then
  echo "hostapd failed to start" >&2
  journalctl -u hostapd -n 40 --no-pager || true
  exit 1
fi

echo "Hotspot started on ${WLAN_IFACE} with SSID ${SSID}"
