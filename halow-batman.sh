#!/usr/bin/env bash
#
# halow-batman.sh -- layer a batman-adv mesh over an IBSS interface.
#
# Run halow-ibss.sh first; this assumes the radio is already in IBSS mode with at
# least one peer. Like that script, this is a bring-up harness rather than a
# production service, and nothing survives a reboot.
#
#   sudo ./halow-batman.sh up          # bat0 over the radio
#   sudo ./halow-batman.sh status      # neighbours, originators, gateways
#   sudo ./halow-batman.sh down        # tear down, leave IBSS alone
#
# The module is NOT installed by this script; see README.md. Check with
# `modinfo batman-adv`.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=halow-lib.sh
source "$ROOT/halow-lib.sh"
LOG_TAG=halow-batman

# --------------------------------------------------------------------------
# Configuration -- edit per node
# --------------------------------------------------------------------------

# Auto-detected by driver, so it works before and after the 10-halow.link
# rename. Set IFACE explicitly to override.
IFACE=${IFACE:-$(default_iface)}
BATIF=${BATIF:-bat0}

# MAC -> name table, installed to /etc/bat-hosts so batctl prints names instead
# of hex. Same file on every node; set empty to skip installing it.
BAT_HOSTS=${BAT_HOSTS:-$ROOT/bat-hosts}

# Name -> bat0 address, merged into /etc/hosts. Set empty to skip.
HOSTS=${HOSTS:-$ROOT/hosts}

# Only used to synthesize the .ibss names in /etc/hosts; must match the value
# halow-ibss.sh used, or the names will point at addresses nothing holds.
IBSS_SUBNET=${IBSS_SUBNET:-192.168.50}

# Derived from the hosts file via this node's identity. Replaces the address
# halow-ibss.sh put on the radio: once batman-adv owns the interface, it must
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

# batctl dropped the old `-m` form; 2024.x wants the `meshif` prefix.
bat() { batctl meshif "$BATIF" "$@"; }

preflight() {
  require_root
  require_cmd batctl "apt install batctl"
  modinfo batman-adv >/dev/null 2>&1 \
    || die "batman-adv module not available; see README.md"

  require_iface "$IFACE"

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

  # The radio must not hold an IP once batman owns it -- halow-ibss.sh puts one
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

  local merged
  merged=$(merge_hosts "$HOSTS" "$IBSS_SUBNET")
  [[ -n $merged ]] && log "merged $merged names into /etc/hosts (.lan and .ibss)"

  if [[ $GW_MODE != off ]]; then
    bat gw_mode "$GW_MODE"
    log "gateway mode: $GW_MODE"
  fi

  log "up. $BATIF has $BAT_IP over $IFACE; run '$0 status'"
}

status() {
  require_root

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
  require_root

  # Flush the address BEFORE anything else. A bat0 left holding 192.168.60.x is
  # the trap that ate a field session: the measurement scripts saw an interface
  # that looked like the mesh and sent every probe into it. They check properly
  # now, but leaving a dead interface addressed is still wrong.
  ip addr flush dev "$BATIF" 2>/dev/null || true
  ip link set "$BATIF" down 2>/dev/null || true

  if ip link show "$BATIF" >/dev/null 2>&1; then
    batctl meshif "$BATIF" interface del "$IFACE" 2>/dev/null ||
      log "warning: could not remove $IFACE from $BATIF"
  fi

  # Removing the last hard interface normally destroys the soft interface. Say
  # so if it survives, rather than leaving it to be discovered in the field.
  if ip link show "$BATIF" >/dev/null 2>&1; then
    log "note: $BATIF still present, but down and unaddressed"
  fi

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
