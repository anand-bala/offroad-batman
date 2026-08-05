#!/usr/bin/env bash
#
# halow-ibss.sh -- bring an MM8108 (802.11ah) interface up in IBSS/adhoc mode.
#
# This validates whether IBSS works at all on S1G with the Morse stack. It is a
# bring-up/test harness, not a production service. Nothing here persists across
# a reboot; that is deliberate.
#
# Run the SAME channel/op_class/ssid on every node. Only NODE_IP differs.
#
#   sudo ./halow-ibss.sh up          # open IBSS, no crypto
#   sudo ./halow-ibss.sh up-rsn      # RSN-IBSS, needs PSK set below
#   sudo ./halow-ibss.sh status      # peers, link, addresses
#   sudo ./halow-ibss.sh down        # tear down, restore managed mode
#
# Expect to lose any SSH session running over the HaLow link. Use the console.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=node-id.sh
source "$ROOT/node-id.sh"

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------

# Auto-detected by driver, so it works before and after the 10-halow.link
# rename. Set IFACE explicitly to override.
IFACE=${IFACE:-$(morse_iface)}
IFACE=${IFACE:-wlan0}
# Derived from the interface, not assumed to be phy0 -- see morse_phy().
PHY=${PHY:-$(morse_phy "$IFACE")}
PHY=${PHY:-phy0}
SSID=${SSID:-HaLow-IBSS}
COUNTRY=${COUNTRY:-US}

# Channel/op_class per the Gateworks table. These are S1G values; the driver
# maps them onto the 5GHz channel numbers that iw/mac80211 will report back,
# so `iw dev` showing "channel 100 (5500 MHz)" is expected, not a bug.
#   1MHz @ 918.5MHz -> channel=33 op_class=68
#   2MHz @ 907MHz   -> channel=10 op_class=69
#   4MHz @ 922MHz   -> channel=40 op_class=70
#   8MHz @ 916MHz   -> channel=28 op_class=71
# Start narrow: 1MHz has the best link budget and is the most likely to work
# at range. Widen only once peering is proven.
CHANNEL=${CHANNEL:-33}
OP_CLASS=${OP_CLASS:-68}

# Derived: identity from the wlan0 MAC via bat-hosts, last octet from the hosts
# file, against the IBSS subnet. Set NODE_IP explicitly to override, or when the
# node is not listed in those files.
IBSS_SUBNET=${IBSS_SUBNET:-192.168.50}
NODE_NAME=${NODE_NAME:-$(node_name "$IFACE" "$ROOT/bat-hosts")}

if [[ -z ${NODE_IP:-} ]]; then
  _bat_ip=$(node_ip "$NODE_NAME" "$ROOT/hosts")
  if [[ -n $_bat_ip ]]; then
    NODE_IP="$IBSS_SUBNET.${_bat_ip##*.}/24"
  fi
  # Deliberately left empty when the lookup fails. preflight() turns that into
  # a clear error; defaulting here would hand an unregistered node the .1
  # address that already belongs to another node.
fi

# Only used by up-rsn. Generate with: openssl rand -base64 24
# Long and random matters here -- see the offline-dictionary caveat for
# RSN-IBSS. A memorable passphrase is the one thing that breaks this.
PSK=${PSK:-}

WORKDIR=${WORKDIR:-/run/halow-ibss}
WPA_S=${WPA_S:-wpa_supplicant_s1g}
CTRL_DIR=/run/wpa_supplicant_s1g

# --------------------------------------------------------------------------

log() { printf '[halow-ibss] %s\n' "$*" >&2; }
die() {
  printf '[halow-ibss] ERROR: %s\n' "$*" >&2
  exit 1
}

preflight() {
  [[ $EUID -eq 0 ]] || die "must run as root"
  command -v "$WPA_S" >/dev/null || die "$WPA_S not found in PATH"
  command -v iw >/dev/null || die "iw not found (apt install iw)"

  if [[ -z ${NODE_IP:-} ]]; then
    die "no address for this node: MAC $(cat "/sys/class/net/$IFACE/address" 2>/dev/null || echo '?') is not in $ROOT/bat-hosts, or '$NODE_NAME' is not in $ROOT/hosts. Add the node to both files, or set NODE_IP=<addr>/24."
  fi

  iw phy "$PHY" info >/dev/null 2>&1 || die "$PHY not present; is morse.ko loaded?"

  # The whole point of the exercise: confirm the driver actually offers IBSS
  # before we try to use it.
  if ! iw phy "$PHY" info | grep -qE '^\s+\* IBSS$'; then
    die "$PHY does not advertise IBSS support"
  fi

  mkdir -p "$WORKDIR" "$CTRL_DIR"
  chmod 700 "$WORKDIR"
}

stop_supplicant() {
  # Kill only supplicants on our interface, not unrelated ones.
  pkill -f "$WPA_S.*-i *$IFACE" 2>/dev/null || true
  sleep 1
}

write_conf() {
  local mode=$1 conf="$WORKDIR/ibss.conf"
  local sec

  if [[ $mode == rsn ]]; then
    [[ -n $PSK ]] || die "up-rsn needs PSK set (openssl rand -base64 24)"
    # RSN-IBSS. No SAE here -- IBSS does not support it.
    sec=$(
      cat <<-EOF
	        key_mgmt=WPA-PSK
	        proto=RSN
	        pairwise=CCMP
	        group=CCMP
	        psk="$PSK"
	EOF
    )
  else
    sec='        key_mgmt=NONE'
  fi

  # mode=1 is IBSS. The s1g channel/op_class keys are the Morse fork's
  # addition -- the same ones the Gateworks mesh example puts in the network
  # block. They are NOT documented for IBSS, so if the supplicant rejects them,
  # set FREQ to the mapped 5GHz frequency instead and we emit that.
  local chan
  if [[ -n ${FREQ:-} ]]; then
    chan="        frequency=$FREQ"
  else
    chan=$(printf '        channel=%s\n        op_class=%s' "$CHANNEL" "$OP_CLASS")
  fi

  cat >"$conf" <<-EOF
	country=$COUNTRY
	ctrl_interface=$CTRL_DIR
	ap_scan=2

	network={
	        ssid="$SSID"
	        mode=1
	$chan
	        country="$COUNTRY"
	        beacon_int=1000
	$sec
	}
	EOF

  chmod 600 "$conf"
  printf '%s' "$conf"
}

bring_up() {
  local mode=$1 conf

  preflight
  stop_supplicant

  conf=$(write_conf "$mode")
  log "config written to $conf (mode=$mode)"

  iw reg set "$COUNTRY" || log "warning: iw reg set failed; continuing"

  ip link set "$IFACE" down 2>/dev/null || true
  iw dev "$IFACE" set type ibss 2>/dev/null ||
    log "warning: could not preset type ibss; letting supplicant do it"
  ip link set "$IFACE" up

  # Foreground with -d on first run is far more informative than backgrounding.
  # Set DEBUG=1 to get that.
  if [[ ${DEBUG:-0} == 1 ]]; then
    log "running in foreground with debug; Ctrl-C to stop"
    "$WPA_S" -i "$IFACE" -c "$conf" -d
    return
  fi

  "$WPA_S" -i "$IFACE" -c "$conf" -B ||
    die "supplicant failed to start; rerun with DEBUG=1"

  sleep 5
  ip addr flush dev "$IFACE"
  ip addr add "$NODE_IP" dev "$IFACE"

  log "up. run '$0 status' here and on the peer."
}

status() {
  echo "=== iw dev $IFACE info ==="
  iw dev "$IFACE" info || true
  echo
  echo "=== link ==="
  iw dev "$IFACE" link || true
  echo
  echo "=== peers (populated only once another node joins) ==="
  iw dev "$IFACE" station dump || true
  echo
  echo "=== addresses ==="
  ip -brief addr show dev "$IFACE" || true
  echo
  echo "=== morse_cli ==="
  morse_cli -i "$IFACE" version 2>/dev/null || echo "morse_cli unavailable"
}

bring_down() {
  [[ $EUID -eq 0 ]] || die "must run as root"
  stop_supplicant
  ip addr flush dev "$IFACE" 2>/dev/null || true
  ip link set "$IFACE" down 2>/dev/null || true
  iw dev "$IFACE" set type managed 2>/dev/null || true
  log "down; $IFACE back in managed mode"
}

case "${1:-}" in
up) bring_up open ;;
up-rsn) bring_up rsn ;;
status) status ;;
down) bring_down ;;
*)
  printf 'usage: %s {up|up-rsn|status|down}\n' "$0" >&2
  exit 2
  ;;
esac
