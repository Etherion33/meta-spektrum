#!/usr/bin/env bash
set -euo pipefail

WLAN_IFACE="${1:-wlan0}"
SHORT_ID="${2:-$(cat /etc/machine-id | cut -c1-6)}"
AP_PASSWORD="${3:-device12345}"
COUNTRY_CODE="${COUNTRY_CODE:-US}"
AP_CHANNELS="${SPEKTRUM_AP_CHANNELS:-11 6 1 13}"

log() {
  echo "[setup_hotspot] $*"
}

ap_is_ready() {
  local iw_type

  if ! ip -4 -o addr show dev "${WLAN_IFACE}" | grep -q '192\.168\.4\.1/24'; then
    return 1
  fi

  iw_type="$(iw dev "${WLAN_IFACE}" info 2>/dev/null | awk '/\ttype / {print $2; exit}')"
  [[ "${iw_type}" == "AP" || "${iw_type}" == "P2P-GO" ]]
}

detect_wifi_iface() {
  local iface candidate

  if [[ -n "${WLAN_IFACE}" ]] && ip link show "${WLAN_IFACE}" >/dev/null 2>&1; then
    echo "${WLAN_IFACE}"
    return 0
  fi

  for _ in $(seq 1 60); do
    for candidate in /sys/class/net/*; do
      iface="$(basename "${candidate}")"
      [[ "${iface}" == "lo" ]] && continue
      [[ "${iface}" == tailscale* ]] && continue
      [[ -d "${candidate}/wireless" ]] || continue
      if ip link show "${iface}" >/dev/null 2>&1; then
        echo "${iface}"
        return 0
      fi
    done

    if command -v nmcli >/dev/null 2>&1; then
      iface="$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null | awk -F: '$2=="wifi" && $1!="" {print $1; exit}')"
      if [[ -n "${iface}" ]] && ip link show "${iface}" >/dev/null 2>&1; then
        echo "${iface}"
        return 0
      fi
    fi

    sleep 1
  done

  return 1
}

try_nm_hotspot() {
  local ch

  if ! command -v nmcli >/dev/null 2>&1; then
    return 1
  fi

  log "Trying NetworkManager hotspot path on ${WLAN_IFACE}"
  timeout 15 nmcli --wait 10 radio wifi on >/dev/null 2>&1 || true
  timeout 15 nmcli --wait 10 dev set "${WLAN_IFACE}" managed yes >/dev/null 2>&1 || true
  timeout 15 nmcli --wait 10 con delete spektrum-ap >/dev/null 2>&1 || true

  for ch in ${AP_CHANNELS}; do
    log "Trying NetworkManager AP channel ${ch}"
    timeout 15 nmcli --wait 10 con delete spektrum-ap >/dev/null 2>&1 || true
    timeout 15 nmcli --wait 10 con add type wifi ifname "${WLAN_IFACE}" con-name spektrum-ap ssid "${SSID}" >/dev/null 2>&1 || true
    timeout 15 nmcli --wait 10 con modify spektrum-ap 802-11-wireless.mode ap 802-11-wireless.band bg 802-11-wireless.channel "${ch}" >/dev/null 2>&1 || true
    timeout 15 nmcli --wait 10 con modify spektrum-ap 802-11-wireless.cloned-mac-address permanent >/dev/null 2>&1 || true
    timeout 15 nmcli --wait 10 con modify spektrum-ap wifi-sec.key-mgmt wpa-psk wifi-sec.psk "${AP_PASSWORD}" >/dev/null 2>&1 || true
    timeout 15 nmcli --wait 10 con modify spektrum-ap ipv4.method shared ipv4.addresses 192.168.4.1/24 ipv6.method ignore >/dev/null 2>&1 || true
    timeout 20 nmcli --wait 15 con up spektrum-ap >/dev/null 2>&1 || true

    for _ in $(seq 1 10); do
      if ap_is_ready; then
        echo "Hotspot started on ${WLAN_IFACE} with SSID ${SSID} (NetworkManager, ch ${ch})"
        return 0
      fi
      sleep 1
    done
  done

  log "NetworkManager hotspot did not obtain 192.168.4.1/24"
  nmcli -t -f NAME,TYPE,DEVICE,ACTIVE con show --active 2>/dev/null || true
  ip -4 addr show dev "${WLAN_IFACE}" 2>/dev/null || true
  return 1
}

if [[ ${#AP_PASSWORD} -lt 8 ]]; then
  echo "AP password must be at least 8 characters" >&2
  exit 1
fi

SSID="Device-${SHORT_ID}"

if ! WLAN_IFACE="$(detect_wifi_iface)"; then
  echo "Wi-Fi interface not found (waited up to 60s)" >&2
  ip -o link show || true
  exit 1
fi

echo "Using Wi-Fi interface: ${WLAN_IFACE}"

install -d /etc/hostapd
install -d /etc/dnsmasq.d
install -d /etc/default

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

if [[ -f /etc/default/hostapd ]]; then
  sed -i 's|^#\?DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd || true
  if ! grep -q '^DAEMON_CONF=' /etc/default/hostapd; then
    printf 'DAEMON_CONF="/etc/hostapd/hostapd.conf"\n' >>/etc/default/hostapd
  fi
else
  printf 'DAEMON_CONF="/etc/hostapd/hostapd.conf"\n' >/etc/default/hostapd
fi

if command -v rfkill >/dev/null 2>&1; then
  rfkill unblock wlan || true
  rfkill unblock wifi || true
fi

if command -v iw >/dev/null 2>&1; then
  iw reg set "${COUNTRY_CODE}" >/dev/null 2>&1 || true
fi

for _ in $(seq 1 10); do
  if ip link show "${WLAN_IFACE}" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! ip link show "${WLAN_IFACE}" >/dev/null 2>&1; then
  echo "Wi-Fi interface ${WLAN_IFACE} disappeared" >&2
  exit 1
fi

if try_nm_hotspot; then
  exit 0
fi

echo "NetworkManager hotspot path failed; trying hostapd/dnsmasq stack" >&2

if command -v nmcli >/dev/null 2>&1; then
  nmcli device disconnect "${WLAN_IFACE}" >/dev/null 2>&1 || true
  nmcli dev set "${WLAN_IFACE}" managed no >/dev/null 2>&1 || true
fi

systemctl stop wpa_supplicant >/dev/null 2>&1 || true

systemctl stop hostapd dnsmasq || true

ip link set "${WLAN_IFACE}" down || true
ip addr flush dev "${WLAN_IFACE}" || true
ip addr add 192.168.4.1/24 dev "${WLAN_IFACE}"
ip link set "${WLAN_IFACE}" up

systemctl unmask hostapd
systemctl enable hostapd dnsmasq
timeout 20 systemctl restart dnsmasq >/dev/null 2>&1 || true
timeout 20 systemctl restart hostapd >/dev/null 2>&1 || true

for _ in $(seq 1 10); do
  if ap_is_ready; then
    break
  fi
  sleep 1
done

if ! systemctl is-active --quiet dnsmasq; then
  echo "dnsmasq failed to start" >&2
  journalctl -u dnsmasq -n 40 --no-pager || true
  HOSTAPD_STACK_FAILED=1
fi

if ! systemctl is-active --quiet hostapd; then
  echo "hostapd failed to start" >&2
  journalctl -u hostapd -n 40 --no-pager || true
  HOSTAPD_STACK_FAILED=1
fi

if ! ap_is_ready; then
  log "AP interface state not ready after hostapd path"
  iw dev "${WLAN_IFACE}" info 2>/dev/null || true
  ip -4 addr show dev "${WLAN_IFACE}" 2>/dev/null || true
  HOSTAPD_STACK_FAILED=1
fi

if [[ "${HOSTAPD_STACK_FAILED:-0}" == "1" ]]; then
  echo "Falling back to NetworkManager hotspot mode" >&2

  if ! command -v nmcli >/dev/null 2>&1; then
    echo "nmcli not available for AP fallback" >&2
    exit 1
  fi

  systemctl stop hostapd dnsmasq >/dev/null 2>&1 || true
  systemctl disable hostapd dnsmasq >/dev/null 2>&1 || true
  if try_nm_hotspot; then
    exit 0
  fi
  log "Final NetworkManager fallback failed"
  nmcli -t -f DEVICE,TYPE,STATE dev status 2>/dev/null || true
  nmcli -t -f NAME,TYPE,DEVICE,ACTIVE con show --active 2>/dev/null || true
  exit 1
fi

if ap_is_ready; then
  echo "Hotspot started on ${WLAN_IFACE} with SSID ${SSID}"
  exit 0
fi

log "AP setup ended without ready AP state"
exit 1
