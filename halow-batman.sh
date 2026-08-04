#!/usr/bin/env bash
#
# halow-batman.sh -- layer a batman-adv mesh over an IBSS interface.
#
# Run halow-ibss.sh first; this assumes wlan0 is already in IBSS mode with at
# least one peer. Like that script, this is a bring-up harness rather than a
# production service, and nothing survives a reboot.
#
#   sudo ./halow-batman.sh up          # bat0 over wlan0
#   sudo ./halow-batman.sh status      # neighbours, originators, gateways
#   sudo ./halow-batman.sh down        # tear down, leave IBSS alone
#
# The module is NOT installed by this script; see README.md. Check with
# `modinfo batman-adv`.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=node-id.sh
source "$ROOT/node-id.sh"

# --------------------------------------------------------------------------
# Configuration -- edit per node
# --------------------------------------------------------------------------

# Auto-detected by driver, so it works before and after the 10-halow.link
# rename. Set IFACE explicitly to override.
IFACE=${IFACE:-$(morse_iface)}
IFACE=${IFACE:-wlan0}
BATIF=${BATIF:-bat0}

# MAC -> name table, installed to /etc/bat-hosts so batctl prints names instead
# of hex. Same file on every node; set empty to skip installing it.
BAT_HOSTS=${BAT_HOSTS:-$ROOT/bat-hosts}

# Name -> bat0 address, merged into /etc/hosts. Set empty to skip.
HOSTS=${HOSTS:-$ROOT/hosts}
HOSTS_BEGIN="# BEGIN halow-batman"
HOSTS_END="# END halow-batman"

# Derived from the hosts file via this node's identity. Replaces the address
# halow-ibss.sh put on wlan0: once batman-adv owns the interface, wlan0 must
# carry no IP of its own, or traffic bypasses the mesh routing entirely.
NODE_NAME=${NODE_NAME:-$(node_name "$IFACE" "$ROOT/bat-hosts")}

if [[ -z ${BAT_IP:-} ]]; then
  _ip=$(node_ip "$NODE_NAME" "$ROOT/hosts")
  BAT_IP="${_ip:-192.168.60.1}/24"
fi

# server on the node with the uplink (the travel router), client on the rest,
# off to disable gateway handling. With client/server set, batman-adv elects a
# gateway and routes to it, replacing any hand-configured default route.
GW_MODE=${GW_MODE:-off}

# BATMAN_IV is the safe default. BATMAN_V picks routes by estimated
# throughput, which leans on the driver reporting sane rate information -- not
# something to assume on an S1G driver this new. Must be set before the mesh
# interface is created; changing it later means a full teardown.
ROUTING_ALGO=${ROUTING_ALGO:-BATMAN_IV}

# batman-adv adds ~28 bytes of header. If the hard interface stays at MTU 1500,
# bat0 comes up around 1472 and anything assuming a 1500-byte path will
# fragment. Setting the hard interface to 1532 keeps bat0 at a clean 1500, but
# whether the Morse driver accepts an oversized MTU is untested -- leave empty
# to skip, and bat0 will simply be smaller.
HARD_MTU=${HARD_MTU:-}

# --------------------------------------------------------------------------

log() { printf '[halow-batman] %s\n' "$*" >&2; }
die() { printf '[halow-batman] ERROR: %s\n' "$*" >&2; exit 1; }

# batctl dropped the old `-m` form; 2024.x wants the `meshif` prefix.
bat() { batctl meshif "$BATIF" "$@"; }

preflight() {
  [[ $EUID -eq 0 ]] || die "must run as root"
  command -v batctl >/dev/null || die "batctl not found (apt install batctl)"
  modinfo batman-adv >/dev/null 2>&1 \
    || die "batman-adv module not available; see README.md"

  ip link show "$IFACE" >/dev/null 2>&1 || die "$IFACE does not exist"

  # batman-adv will happily run over an interface with no peers and give you a
  # mesh of one, which looks healthy and forwards nothing. Warn rather than
  # fail: a solo node is legitimate while bringing the fleet up one at a time.
  local type
  type=$(iw dev "$IFACE" info 2>/dev/null | awk '/^\ttype /{print $2}')
  [[ $type == "IBSS" ]] || log "warning: $IFACE type is '${type:-unknown}', expected IBSS"

  if ! iw dev "$IFACE" station dump 2>/dev/null | grep -q '^Station'; then
    log "warning: no IBSS peers on $IFACE -- bat0 will be a mesh of one"
  fi
}

bring_up() {
  preflight

  modprobe batman-adv
  log "routing algorithm: $ROUTING_ALGO"
  batctl routing_algo "$ROUTING_ALGO" \
    || die "could not set routing algo (already have a mesh interface up?)"

  if [[ -n $HARD_MTU ]]; then
    ip link set "$IFACE" mtu "$HARD_MTU" \
      || log "warning: $IFACE rejected MTU $HARD_MTU; bat0 will be undersized"
  fi

  # wlan0 must not hold an IP once batman owns it -- halow-ibss.sh puts one
  # there, and leaving it would let traffic take the direct path and silently
  # skip the mesh.
  ip addr flush dev "$IFACE"

  bat interface add "$IFACE" || die "could not add $IFACE to $BATIF"
  ip link set "$BATIF" up

  ip addr flush dev "$BATIF" 2>/dev/null || true
  ip addr add "$BAT_IP" dev "$BATIF"

  if [[ -n $BAT_HOSTS && -f $BAT_HOSTS ]]; then
    install -m 0644 "$BAT_HOSTS" /etc/bat-hosts
    log "installed $(grep -cvE '^\s*(#|$)' "$BAT_HOSTS") names to /etc/bat-hosts"
  fi

  # /etc/hosts is never overwritten -- only the marked block is replaced, so
  # localhost and anything else the distro put there survives.
  if [[ -n $HOSTS && -f $HOSTS ]]; then
    local tmp
    tmp=$(mktemp)
    sed "\|^${HOSTS_BEGIN}\$|,\|^${HOSTS_END}\$|d" /etc/hosts > "$tmp"
    {
      echo "$HOSTS_BEGIN"
      grep -vE '^\s*(#|$)' "$HOSTS"
      echo "$HOSTS_END"
    } >> "$tmp"
    install -m 0644 "$tmp" /etc/hosts
    rm -f "$tmp"
    log "merged $(grep -cvE '^\s*(#|$)' "$HOSTS") names into /etc/hosts"
  fi

  if [[ $GW_MODE != off ]]; then
    bat gw_mode "$GW_MODE"
    log "gateway mode: $GW_MODE"
  fi

  log "up. $BATIF has $BAT_IP over $IFACE; run '$0 status'"
}

status() {
  [[ $EUID -eq 0 ]] || die "must run as root"

  echo "=== interfaces in the mesh ==="
  bat interface || true
  echo
  echo "=== direct neighbours ==="
  bat neighbors || true
  echo
  echo "=== originators (every node, next hop, link quality) ==="
  bat originators || true
  echo
  echo "=== gateways ==="
  bat gwl || true
  echo
  echo "=== addresses ==="
  ip -brief addr show "$BATIF" || true
  ip -brief addr show "$IFACE" || true
  echo
  echo "=== underlying IBSS peers ==="
  iw dev "$IFACE" station dump 2>/dev/null | grep -E '^Station|signal:|tx bitrate' || true
}

bring_down() {
  [[ $EUID -eq 0 ]] || die "must run as root"

  ip link set "$BATIF" down 2>/dev/null || true
  batctl meshif "$BATIF" interface del "$IFACE" 2>/dev/null || true

  # Deliberately leaves the IBSS up and the module loaded: this tears down the
  # routing layer only, so the transport underneath can be tested on its own.
  log "down; $IFACE left in IBSS mode without an address"
  log "re-run halow-ibss.sh up to restore its IP for direct testing"
}

case "${1:-}" in
  up)      bring_up ;;
  status)  status ;;
  down)    bring_down ;;
  *)       printf 'usage: %s {up|status|down}\n' "$0" >&2; exit 2 ;;
esac
