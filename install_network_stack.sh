#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# --------------------------------------------------------------------------------
# Preamble
# --------------------------------------------------------------------------------

log() { >&2 echo "==> $*"; }
err() { >&2 echo "ERROR: $*"; }

die() {
  err "$*"
  exit 1
}

as_root() { if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi; }

# require_cmd <name> [hint] -- hint is usually the package to install.
#
# Also searches the sbin directories explicitly. A non-root user's PATH on
# Debian omits them, so `command -v iw` says "missing" for a tool that is
# installed and that the units (running as root) will resolve fine.
require_cmd() {
  local d
  command -v "$1" >/dev/null && return 0
  for d in /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin; do
    [[ -x $d/$1 ]] && return 0
  done
  die "$1 not found${2:+ ($2)}"
}

# require_iface <iface>
require_iface() {
  ip link show "$1" >/dev/null 2>&1 || die "$1 does not exist"
}

# preflight -- fail here, with the fix, rather than at boot on the node.
#
# The units call these by bare name and let systemd resolve them, so a missing
# tool shows up as a restart loop in the journal long after the install looked
# like it worked. Check once, up front, while there is still a terminal to
# print the remedy to.
preflight() {
  require_cmd ip "apt install iproute2"
  require_cmd iw "apt install iw"
  require_cmd rfkill "apt install rfkill"
  require_cmd ethtool "apt install ethtool"
  require_cmd batctl "apt install batctl"
  require_cmd hostnamectl "apt install systemd"
  require_cmd wpa_supplicant_s1g "run ./build_dependencies.sh"

  # Both modules are named in modules-load.d/halow-mesh.conf, and
  # systemd-modules-load.service fails the boot into degraded state over a name
  # it cannot resolve. Checking here turns that into an install-time error with
  # a fix attached, rather than a red unit on a node in the field.
  modinfo batman-adv >/dev/null 2>&1 ||
    die "batman-adv module not available (apt install batman-adv-dkms, or run ./build_dependencies.sh)"
  modinfo morse >/dev/null 2>&1 ||
    die "morse module not available (run ./build_dependencies.sh)"

  # The `resolve` entry written into /etc/nsswitch.conf below is inert without
  # this NSS module, and Debian ships it in its own package, separate from
  # systemd. Missing it means getaddrinfo() never asks resolved, so every
  # <hostname>.local lookup fails while resolvectl still answers happily --
  # the kind of split that is genuinely hard to read from the symptom.
  compgen -G '/usr/lib*/libnss_resolve.so.2' >/dev/null ||
    compgen -G '/usr/lib/*/libnss_resolve.so.2' >/dev/null ||
    die "libnss_resolve.so.2 not found (apt install libnss-resolve)"
}

# halow_iface -- the netdev bound to the Morse driver, whatever it is called.
#
# The card is USB, so before any rename the kernel hands it a MAC-derived name
# like wlx0cbf74005bc8, different on every node. After installing
# 10-halow.link it is halow0. Detecting by driver means the scripts work either
# way, and on all four nodes, with no per-node configuration.
halow_iface() {
  local d drv
  for d in /sys/class/net/*; do
    [[ -e $d/device/driver ]] || continue
    drv=$(basename "$(readlink -f "$d/device/driver")" 2>/dev/null || true)
    case $drv in
    morse*)
      basename "$d"
      return 0
      ;;
    esac
  done
  return 0
}

# halow_phy <iface> -- the wiphy that netdev belongs to.
#
# Not necessarily phy0. The index is handed out in registration order, so any
# node with a second wireless device (an onboard card, a USB dongle) can push
# the Morse card to phy1 or higher. It is not stable across module reloads
# either: unloading and reloading morse.ko moves the card to the next free
# index. Reading it back from the netdev is the only reliable answer.
# Plain readlink, not readlink -f: -f canonicalises a path whose final
# component does not exist, so a non-wireless interface would yield the
# literal string "phy80211" rather than nothing.
halow_phy() {
  local iface link
  iface="${1?missing \'iface\' argument, aborting}"
  [[ -L /sys/class/net/$iface/phy80211 ]] || return 0
  link=$(readlink "/sys/class/net/$iface/phy80211" 2>/dev/null || true)
  [[ -n $link ]] && basename "$link"
  return 0
}

# iface_mac <iface> -- the permanent (burned-in) MAC of iface.
#
# Prefers ethtool -P over the sysfs address: sysfs reflects whatever MAC is
# currently assigned, but the ULA suffix derived from this must stay stable
# across reboots, so the permanent address is the correct source when the
# driver exposes one. Falls back to sysfs when ethtool is unavailable or the
# driver doesn't implement the permaddr ioctl (returns all zeroes).
iface_mac() {
  local iface="${1?missing \'iface\' argument, aborting}"
  local mac
  mac=$(ethtool -P "$iface" 2>/dev/null | awk '{print $NF}') || true
  [[ $mac =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ && $mac != 00:00:00:00:00:00 ]] ||
    mac=$(cat "/sys/class/net/$iface/address")
  printf '%s' "$mac"
}

# node_name <iface> [<bat_hosts_file>] -- this node's name, for hostnamectl.
#
# Precedence: an explicit $NODE_NAME env override, then a lookup of iface's
# MAC in bat_hosts (if given), then whatever hostname is already set.
node_name() {
  local iface="${1?missing \'iface\' argument, aborting}"
  local bat_hosts="${2:-}"
  local mac name

  if [[ -n ${NODE_NAME:-} ]]; then
    printf '%s' "$NODE_NAME"
    return 0
  fi

  mac=$(iface_mac "$iface")

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

# eui64_from_mac <mac> -- the EUI-64 interface identifier for a MAC.
#
# Flips the MAC's universal/local bit and inserts ff:fe in the middle, per
# RFC 4291 appendix A. This is the lower 64 bits appended to $ULA_PREFIX to
# form a node's static address.
#
# Takes a MAC rather than an interface because it is used two ways: for this
# node, whose MAC is read off its own radio, and for every peer, whose MAC is
# known only from bat-hosts and has no local interface to read.
eui64_from_mac() {
  local mac="${1?missing \'mac\' argument, aborting}"
  local a b c d e f
  IFS=: read -r a b c d e f <<<"$mac"

  printf '%02x%s:%sff:fe%s:%s%s' "$((0x$a ^ 2))" "$b" "$c" "$d" "$e" "$f"
}

# eui64_identifier <iface> -- eui64_from_mac against iface's permanent MAC.
# The address must be stable across reboots, hence iface_mac and not sysfs.
eui64_identifier() {
  local iface="${1?missing \'iface\' argument, aborting}"
  eui64_from_mac "$(iface_mac "$iface")"
}

# Markers for this script's block in /etc/hosts. Deliberately the same strings
# halow-lib.sh used: a node set up by the old scripts already carries a block
# under these markers, and changing the wording would leave that one orphaned
# in place -- stale IPv4 entries, shadowing nothing, impossible to spot -- next
# to a second block that actually works.
HOSTS_BEGIN="# BEGIN halow-batman"
HOSTS_END="# END halow-batman"

# merge_hosts <bat_hosts> -- static mesh addresses for the whole fleet.
#
# Every node's address is derivable here, not just this one's: bat-hosts holds
# every radio MAC, the ULA prefix is fleet-wide, and EUI-64 is deterministic.
# So one table generates the whole roster with nothing to keep in sync by hand.
#
# The names are <name>.mesh plus the bare <name> -- NOT <name>.local. RFC 6762
# reserves .local for mDNS, and since nsswitch reads files before resolve, a
# static .local entry would permanently shadow mDNS for that name: a stale
# entry would win forever and the mDNS path would never be exercised. Keeping
# the suffixes apart means a failure says which layer broke -- .mesh failing is
# the roster or the address derivation, .local failing is mDNS/resolved/NSS,
# both failing is the mesh itself.
#
# Only the marked block is replaced, so localhost and anything else the distro
# or the operator put in /etc/hosts survives, and reruns are idempotent.
merge_hosts() {
  local bat_hosts="${1?missing \'bat_hosts\' argument, aborting}"
  local tmp mac name

  [[ -f $bat_hosts && -f /etc/hosts ]] || return 0

  tmp=$(mktemp)
  sed "\|^${HOSTS_BEGIN}\$|,\|^${HOSTS_END}\$|d" /etc/hosts >"$tmp"
  {
    echo "$HOSTS_BEGIN"
    while read -r mac name; do
      # Tolerate a .lan suffix left in a node's hand-edited bat-hosts from the
      # retired IPv4 scheme; the shipped table no longer carries one.
      name=${name%.lan}
      printf '%s:%s\t%s.mesh\t%s\n' \
        "$ULA_PREFIX" "$(eui64_from_mac "$mac")" "$name" "$name"
    done < <(grep -vE '^[[:space:]]*(#|$)' "$bat_hosts")
    echo "$HOSTS_END"
  } >>"$tmp"

  as_root install -o root -g root -m 0644 "$tmp" /etc/hosts
  rm -f "$tmp"

  grep -cvE '^[[:space:]]*(#|$)' "$bat_hosts"
}

# --------------------------------------------------------------------------------
# Variables
# --------------------------------------------------------------------------------

preflight

# The shared Unique Local Address (IPv6) prefix for the whole fleet
#
# Generated a single random RFC 4193 `/64` and should be reused on every node.
# **Never** regenerate per node -- a per-node prefix silently partitions the mesh.
#
# Generated using:
#
# printf 'fd%s:%s:%s:0\n' \
#   "$(openssl rand -hex 1)" \
#   "$(openssl rand -hex 2)" \
#   "$(openssl rand -hex 2)"
: "${ULA_PREFIX:=fdc7:37f3:e24a:0}"

# The HaLow netdev, detected by driver (see halow_iface).
RADIO=$(halow_iface)
[[ -n $RADIO ]] || die "no morse* radio found"

# RADIO's permanent MAC (see iface_mac), used to derive IPV6_ADDR and, via
# bat-hosts, NODE_NAME.
MAC=$(iface_mac "$RADIO")

# This node's static mesh address: the shared /64 plus a MAC-derived EUI-64
# suffix, stamped into etc/systemd/network/25-bat0.network below.
IPV6_ADDR="${ULA_PREFIX}:$(eui64_identifier "$RADIO")/64"

# This node's hostname, which drives <hostname>.local over mDNS. See
# node_name for the lookup order; override by exporting NODE_NAME.
: "${NODE_NAME:=$(node_name "$RADIO" ./etc/bat-hosts)}"

log "Setting up B.A.T.M.A.N. networking stack as follows:

  Device Hostname:    ${NODE_NAME}
  HaLow Interface:    ${RADIO}
  HaLow MAC Address:  ${MAC}
  IPv6 Address:       ${IPV6_ADDR}
"

# --------------------------------------------------------------------------------
# Install the files
# --------------------------------------------------------------------------------

# 0644 for everything except the supplicant conf. bat-hosts is included: these
# nodes only ever run the one mesh, so the shipped table is authoritative and
# overwriting it is the intended behaviour.
while IFS= read -r f; do
  as_root install -D -o root -g root -m 0644 "$f" "/$f"
done < <(find etc -type f ! -name 'wpa_supplicant-halow0.conf')

# Supplicant conf may hold a PSK -> 0600.
as_root install -D -o root -g root -m 0600 \
  etc/wpa_supplicant/wpa_supplicant-halow0.conf \
  /etc/wpa_supplicant/wpa_supplicant-halow0.conf

# Stamp this node's ULA address into the installed copy of 25-bat0.network.
# Done to a temp copy, never in place: an in-place sed dirties the working tree
# and bakes one node's address into the repo, which then travels to the next
# node as its apparent default.
STAMPED=$(mktemp)
trap 'rm -f "$STAMPED"' EXIT
sed -E "s|^Address=.*|Address=${IPV6_ADDR}|" \
  etc/systemd/network/25-bat0.network >"$STAMPED"
as_root install -D -o root -g root -m 0644 \
  "$STAMPED" /etc/systemd/network/25-bat0.network

# Hostname (drives <hostname>.local).
# TODO: I feel like we should actually prefer the already set hostname on the device.
as_root hostnamectl set-hostname "$NODE_NAME"

# Normalise NSS to route .local through systemd-resolved (matches mdns.conf),
# and retire avahi so the two mDNS stacks don't collide. Idempotent.
#
# Rewrites the hosts: line only. Two things to recognise there, in any order
# and in any of their spellings:
#
#   mdns entries      any of mdns, mdns4, mdns6, mdns4_minimal, mdns6_minimal,
#                     each optionally followed by a bracketed action such as
#                     [NOTFOUND=return]. These are avahi's NSS module; all are
#                     dropped, action included.
#   a resolve entry   optionally followed by its own bracketed action. Exactly
#                     one must end up present, spelled
#                     `resolve [!UNAVAIL=return]`, placed after files so the
#                     static table still wins. Any existing one is dropped and
#                     reinserted rather than edited in place, which normalises
#                     a differing action and makes reruns converge.
#
# A hosts: line carrying neither pattern is the case that matters most: there
# is nothing to rewrite, but .local still has to resolve, so the resolve entry
# is inserted regardless.
fix_nsswitch() {
  local tmp
  [[ -f /etc/nsswitch.conf ]] || return 0

  tmp=$(mktemp)
  awk '
    /^hosts:/ {
      out = ""
      for (i = 2; i <= NF; i++) {
        if ($i ~ /^mdns[46]?(_minimal)?$/) {
          if ($(i+1) ~ /^\[/) i++     # swallow its [NOTFOUND=return]
          continue
        }
        if ($i == "resolve") { if ($(i+1) ~ /^\[/) i++; continue }
        out = out " " $i
        if ($i == "files") out = out " resolve [!UNAVAIL=return]"
      }
      if (out !~ /resolve/) out = " resolve [!UNAVAIL=return]" out
      print "hosts:" out
      next
    }
    { print }
  ' /etc/nsswitch.conf >"$tmp"

  as_root install -o root -g root -m 0644 "$tmp" /etc/nsswitch.conf
  rm -f "$tmp"
}
fix_nsswitch
as_root systemctl mask --now avahi-daemon.service avahi-daemon.socket 2>/dev/null || true

# Static <name>.mesh entries for the fleet, alongside mDNS's <name>.local.
log "wrote $(merge_hosts ./etc/bat-hosts) node(s) into /etc/hosts as <name>.mesh"

# Reload and enable. halow0-ibss has no [Install]; it is pulled by the udev
# rule and by halow0-attach's Requires=.
as_root systemctl daemon-reload
as_root udevadm control --reload
as_root systemctl enable systemd-networkd systemd-resolved halow0-attach.service
