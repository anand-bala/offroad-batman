# node-id.sh -- work out which node this is, and what address it should hold.
# Sourced by halow-ibss.sh and halow-batman.sh; not executable on its own.
#
# Identity comes from the wlan0 MAC looked up in bat-hosts, so the same files
# ship to every node unchanged and nothing has to be edited per device. Falls
# back to the system hostname, then to whatever the caller defaulted to.
#
# The address then comes from the hosts file, which holds bat0 addresses. The
# IBSS address reuses its last octet against a different subnet, so one entry
# per node drives both layers and they cannot drift apart.

# morse_iface -- the netdev bound to the Morse driver, whatever it is called.
#
# The card is USB, so before any rename the kernel hands it a MAC-derived name
# like wlx0cbf74005bc8, different on every node. After installing
# 10-halow.link it is halow0. Detecting by driver means the scripts work either
# way, and on all four nodes, with no per-node configuration.
morse_iface() {
  local d drv
  for d in /sys/class/net/*; do
    [[ -e $d/device/driver ]] || continue
    drv=$(basename "$(readlink -f "$d/device/driver")" 2>/dev/null || true)
    case $drv in
      morse*) basename "$d"; return 0 ;;
    esac
  done
  return 0
}

# morse_phy <iface> -- the wiphy that netdev belongs to.
#
# Not necessarily phy0. The index is handed out in registration order, so any
# node with a second wireless device (an onboard card, a USB dongle) can push
# the Morse card to phy1 or higher. It is not stable across module reloads
# either: unloading and reloading morse.ko moves the card to the next free
# index. Reading it back from the netdev is the only reliable answer.
# Plain readlink, not readlink -f: -f canonicalises a path whose final
# component does not exist, so a non-wireless interface would yield the
# literal string "phy80211" rather than nothing.
morse_phy() {
  local iface=${1:-} link
  [[ -n $iface ]] || return 0
  [[ -L /sys/class/net/$iface/phy80211 ]] || return 0
  link=$(readlink "/sys/class/net/$iface/phy80211" 2>/dev/null || true)
  [[ -n $link ]] && basename "$link"
  return 0
}

# node_name <iface> <bat_hosts_file>
node_name() {
  local iface=$1 bat_hosts=$2 mac name

  if [[ -n ${NODE_NAME:-} ]]; then
    printf '%s' "$NODE_NAME"
    return 0
  fi

  mac=$(cat "/sys/class/net/$iface/address" 2>/dev/null || true)
  if [[ -n $mac && -f $bat_hosts ]]; then
    name=$(awk -v m="${mac,,}" '
      /^[[:space:]]*(#|$)/ {next}
      tolower($1) == m {print $2; exit}' "$bat_hosts")
    if [[ -n $name ]]; then
      printf '%s' "$name"
      return 0
    fi
  fi

  hostname 2>/dev/null || true
}

# node_ip <name> <hosts_file> -- match against every alias on the line, so
# either "olo.lan" or "olo" resolves.
node_ip() {
  local name=$1 hosts=$2
  [[ -n $name && -f $hosts ]] || return 0
  awk -v n="$name" '
    /^[[:space:]]*(#|$)/ {next}
    { for (i = 2; i <= NF; i++) if ($i == n) { print $1; exit } }' "$hosts"
}
