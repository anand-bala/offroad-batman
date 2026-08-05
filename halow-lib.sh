# halow-lib.sh -- shared helpers for the HaLow bring-up and measurement scripts.
# Sourced by halow-ibss.sh, halow-batman.sh and halow-measure.sh; not executable
# on its own.
#
# Everything here was duplicated across those scripts before. That mattered
# beyond tidiness: the pingif selection and the RSSI sampler existed in two
# copies each, so a fix to either had to be made twice, and one that was made
# once drifted.
#
# Two groups of helpers:
#
#   identity   which node this is, and what address it should hold
#   sampling   read link quality out of iw/batctl
#
# Identity comes from the radio MAC looked up in bat-hosts, so the same files
# ship to every node unchanged and nothing has to be edited per device. Falls
# back to the system hostname, then to whatever the caller defaulted to.
#
# The address then comes from the hosts file, which holds bat0 addresses. The
# IBSS address reuses its last octet against a different subnet, so one entry
# per node drives both layers and they cannot drift apart.

# --------------------------------------------------------------------------
# Logging
# --------------------------------------------------------------------------

# Each script sets LOG_TAG after sourcing; the default keeps output sane if one
# forgets. Resolved at call time, so the assignment order does not matter.
LOG_TAG=${LOG_TAG:-halow}

log() { printf '[%s] %s\n' "$LOG_TAG" "$*" >&2; }
die() {
  printf '[%s] ERROR: %s\n' "$LOG_TAG" "$*" >&2
  exit 1
}

# --------------------------------------------------------------------------
# Preflight
# --------------------------------------------------------------------------

# require_root [why] -- the optional argument explains what needs the
# privilege, worth having where it is not obvious (ping interval, iw access).
require_root() {
  [[ $EUID -eq 0 ]] || die "must run as root${1:+ ($1)}"
}

# require_cmd <name> [hint] -- hint is usually the package to install.
require_cmd() {
  command -v "$1" >/dev/null || die "$1 not found${2:+ ($2)}"
}

require_iface() {
  ip link show "$1" >/dev/null 2>&1 || die "$1 does not exist"
}

# --------------------------------------------------------------------------
# Identity
# --------------------------------------------------------------------------

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
    morse*)
      basename "$d"
      return 0
      ;;
    esac
  done
  return 0
}

# default_iface -- morse_iface, falling back to the post-rename name when
# detection finds nothing (card unplugged, or morse.ko not loaded yet).
# Callers still let IFACE override.
default_iface() {
  local i
  i=$(morse_iface)
  printf '%s' "${i:-halow0}"
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

# --------------------------------------------------------------------------
# Sampling
# --------------------------------------------------------------------------

# sample_rssi <iface> [peer_mac] -- pull the signal figure for the peer of
# interest. `iw` prints e.g.
#	signal:  	-52 [-53, -60] dBm
# An empty peer_mac takes the first station listed: what you want with exactly
# two nodes up, and arbitrary with more.
sample_rssi() {
  local iface=$1 peer_mac=${2:-} dump
  dump=$(iw dev "$iface" station dump 2>/dev/null || true)

  if [[ -n $peer_mac ]]; then
    printf '%s' "$dump" | awk -v mac="$peer_mac" '
      tolower($0) ~ "^station " tolower(mac) {want=1; next}
      /^Station/ {want=0}
      want && /signal:/ {print $2; exit}'
  else
    printf '%s' "$dump" | awk '/signal:/ {print $2; exit}'
  fi
}

# sample_bitrate <iface> -- negotiated TX rate in Mbit/s.
sample_bitrate() {
  iw dev "$1" station dump 2>/dev/null |
    awk '/tx bitrate:/ {print $3; exit}' || true
}

# tq_best -- highest (nnn) figure from an originators dump on stdin.
tq_best() {
  awk '{ if (match($0, /\([ ]*[0-9]+\)/)) {
           v=substr($0, RSTART+1, RLENGTH-2); gsub(/ /,"",v);
           if (v+0 > best) best=v+0 } }
       END {if (best) print best}'
}

# sample_tq <meshif> -- best batman link quality, 0-255. Silent when batctl or
# the interface is absent.
#
# This is the BEST originator, which is the peer only while exactly two nodes
# are up. With the full fleet running, read the originators dump instead.
sample_tq() {
  local meshif=$1
  command -v batctl >/dev/null || return 0
  ip link show "$meshif" >/dev/null 2>&1 || return 0
  batctl meshif "$meshif" originators 2>/dev/null | tq_best || true
}

# mesh_usable <meshif> -- true only when the mesh interface can actually carry
# traffic: present, UP, addressed, and with at least one hard interface in it.
#
# Existence alone is not enough, and assuming it was cost us a field session.
# `halow-batman.sh down` leaves bat0 behind -- down, and formerly still holding
# its address -- so an existence test silently routed every probe into a dead
# interface and reported a link that was never tried.
mesh_usable() {
  local meshif=$1

  ip link show "$meshif" >/dev/null 2>&1 || return 1
  ip link show "$meshif" 2>/dev/null | head -1 | grep -q '[<,]UP[,>]' || return 1
  ip -4 addr show dev "$meshif" 2>/dev/null | grep -q 'inet ' || return 1

  # A mesh with no hard interface forwards nothing. Only checkable with batctl;
  # skip the test rather than fail when it is absent.
  if command -v batctl >/dev/null; then
    batctl meshif "$meshif" interface 2>/dev/null | grep -q ':' || return 1
  fi

  return 0
}

# ping_iface <iface> <meshif> -- which interface to send test traffic over.
# Prefers the mesh interface when it is usable, so a test measures the path the
# deployment will actually use, and says so when it falls back: a silent
# fallback is indistinguishable from a broken link in the resulting CSV.
ping_iface() {
  local iface=$1 meshif=$2

  if mesh_usable "$meshif"; then
    printf '%s' "$meshif"
    return 0
  fi

  if ip link show "$meshif" >/dev/null 2>&1; then
    log "note: $meshif exists but is not usable (down, unaddressed, or empty); measuring over $iface"
  fi
  printf '%s' "$iface"
}

# --------------------------------------------------------------------------
# /etc/hosts
# --------------------------------------------------------------------------

# The marker is still named for halow-batman because that script wrote it
# first: renaming it would orphan the existing block on any node already set
# up, leaving two. Both bring-up scripts write the same content now.
HOSTS_BEGIN="# BEGIN halow-batman"
HOSTS_END="# END halow-batman"

# merge_hosts <hosts_file> <ibss_subnet> -- replace the marked block in
# /etc/hosts with the bat0 names, plus .ibss names for the same nodes.
#
# /etc/hosts is never overwritten -- only the marked block is replaced, so
# localhost and anything else the distro put there survives, and repeated runs
# are idempotent.
#
# The .ibss names are synthesized rather than stored, keeping one table as the
# single source of truth. Without them there is no name for the IBSS address at
# all, which makes step 1 of the bring-up -- two nodes, open IBSS, ping -- a
# by-IP-only exercise, and invites reaching for a .60 address over a link where
# only .50 exists.
merge_hosts() {
  local hosts=$1 ibss_subnet=$2 tmp

  [[ -n $hosts && -f $hosts ]] || return 0

  tmp=$(mktemp)
  sed "\|^${HOSTS_BEGIN}\$|,\|^${HOSTS_END}\$|d" /etc/hosts >"$tmp"
  {
    echo "$HOSTS_BEGIN"
    grep -vE '^\s*(#|$)' "$hosts"
    awk -v net="$ibss_subnet" '
      /^[[:space:]]*(#|$)/ {next}
      { n = split($1, o, ".")
        name = $2; gsub(/\.lan$/, "", name)
        printf "%s.%s      %s.ibss\n", net, o[n], name }' "$hosts"
    echo "$HOSTS_END"
  } >>"$tmp"
  install -m 0644 "$tmp" /etc/hosts
  rm -f "$tmp"

  printf '%s' "$(grep -cvE '^\s*(#|$)' "$hosts")"
}
