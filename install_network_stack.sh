#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# --------------------------------------------------------------------------------
# Preamble
# --------------------------------------------------------------------------------

# Identity, addressing and /etc/hosts all come from the library, which is also
# what batman_oracle.sh reads them through. They were duplicated here before,
# which meant the installer and the diagnostics could disagree about a node's
# name or address -- the one disagreement neither tool can report, because each
# is individually self-consistent.
# shellcheck source=halow-lib.sh
source "$SCRIPT_DIR/halow-lib.sh"
# shellcheck disable=SC2034  # read by log()/warn()/die() in the library
LOG_TAG=install

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
  require_cmd chronyc "apt install chrony"

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

# The HaLow netdev, detected by driver (see morse_iface).
RADIO=$(morse_iface)
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

# The IPv4 half of the mesh: the router's LAN, which bat0 is bridged into on the
# router side. MESH_V4_GATEWAY is the router's own address on it, and is written
# down rather than derived -- it belongs to br-ahwlan, which is UCI's to set and
# has no roster entry to derive from.
#
# MESH_V4_BASE offsets node addresses away from .1 and keeps them below the
# dnsmasq pool that starts at .100, so a node can never be handed an address a
# laptop already holds. See node_mesh_addr4, which enforces both bounds.
: "${MESH_V4_SUBNET:=192.168.12}"
: "${MESH_V4_BASE:=10}"
: "${MESH_V4_GATEWAY:=${MESH_V4_SUBNET}.1}"

# This node's static IPv4 on that LAN, from its roster position. Empty when the
# node is absent from the roster or the roster has outgrown the usable octets,
# in which case the mesh still comes up v6-only -- degraded, but not broken.
IPV4_ADDR=$(node_mesh_addr4 "$NODE_NAME" ./etc/bat-hosts "$MESH_V4_SUBNET" "$MESH_V4_BASE")
if [[ -n $IPV4_ADDR ]]; then
  IPV4_ADDR="${IPV4_ADDR}/24"
else
  warn "no IPv4 for '${NODE_NAME}': absent from etc/bat-hosts, or past the usable range"
  warn "this node will be IPv6-only, and the v4-only uplink will be unreachable from it"
fi

# The roster name of the node holding the uplink -- the OpenWrt travel router.
# Its mesh address becomes every other node's default route. Override by
# exporting GATEWAY_NAME; set it empty to install no default route at all,
# which is the right thing on the gateway itself and on an isolated bench pair.
: "${GATEWAY_NAME:=heylo-base}"

# GATEWAY_ADDR -- the uplink's mesh address, derived rather than written down.
#
# Same derivation as every other node's: its radio MAC out of the roster,
# EUI-64'd against the fleet prefix. Deriving it means a ULA_PREFIX override
# moves the gateway with the fleet, where a literal address would silently
# point at the old prefix and every node would lose its route out.
#
# Empty when this node IS the gateway (it does not route to itself), when
# GATEWAY_NAME is cleared, or when the name is absent from the roster.
GATEWAY_ADDR=""
GATEWAY4_ADDR=""
if [[ -n $GATEWAY_NAME && $GATEWAY_NAME != "$NODE_NAME" ]]; then
  GATEWAY_ADDR=$(node_mesh_addr "$GATEWAY_NAME" ./etc/bat-hosts "$ULA_PREFIX")
  if [[ -z $GATEWAY_ADDR ]]; then
    # Not fatal: the mesh still works, this node just has no way out. Say so
    # loudly rather than leaving it to be found by a failed ping in the field.
    warn "gateway '$GATEWAY_NAME' not in etc/bat-hosts; no default route will be set"
  fi
  # The v4 gateway is not derived and so cannot go missing the same way. It is
  # gated on the same condition only so that a node declared to be the gateway,
  # or a bench pair with GATEWAY_NAME cleared, gets no default route in either
  # family -- one stack routing to an absent router while the other does not is
  # a worse state to debug than neither doing so.
  GATEWAY4_ADDR="$MESH_V4_GATEWAY"
fi

log "Setting up B.A.T.M.A.N. networking stack as follows:

  Device Hostname:    ${NODE_NAME}
  HaLow Interface:    ${RADIO}
  HaLow MAC Address:  ${MAC}
  IPv6 Address:       ${IPV6_ADDR}
  IPv4 Address:       ${IPV4_ADDR:-<none> (not in the roster, or past the usable range)}
  Default Route:      ${GATEWAY_ADDR:-<none> (this node is the gateway, or none is configured)}
  Default Route (v4): ${GATEWAY4_ADDR:-<none> (this node is the gateway, or none is configured)}
"

# --------------------------------------------------------------------------------
# Install the files
# --------------------------------------------------------------------------------

# 0644 for everything except the supplicant conf. bat-hosts is included: these
# nodes only ever run the one mesh, so the shipped table is authoritative and
# overwriting it is the intended behaviour.
#
# 25-bat0.network is excluded and installed by the stamping block below instead.
# Copying the template here first would put a file full of placeholders into
# /etc, and an install that then died before stamping would leave the node with
# a .network networkd rejects outright -- no mesh address, over a failure that
# happened after the file was already in place.
while IFS= read -r f; do
  as_root install -D -o root -g root -m 0644 "$f" "/$f"
done < <(find etc -type f ! -name 'wpa_supplicant-halow0.conf' \
  ! -name '25-bat0.network' \
  ! -path 'etc/NetworkManager/dispatcher.d/*')

# Readiness gates called from both units' ExecStartPre=. Outside etc/, so it is
# not covered by the sweep above, and 0755 rather than 0644 because systemd
# execs it directly.
as_root install -D -o root -g root -m 0755 \
  usr/local/lib/halow/halow-wait \
  /usr/local/lib/halow/halow-wait

# Supplicant conf may hold a PSK -> 0600.
as_root install -D -o root -g root -m 0600 \
  etc/wpa_supplicant/wpa_supplicant-halow0.conf \
  /etc/wpa_supplicant/wpa_supplicant-halow0.conf

# Dispatcher hooks must be executable or NetworkManager silently ignores
# them -> 0755, excluded from the 0644 sweep above.
as_root install -D -o root -g root -m 0755 \
  etc/NetworkManager/dispatcher.d/90-dns-mesh-coexist \
  /etc/NetworkManager/dispatcher.d/90-dns-mesh-coexist

# Stamp this node's addresses, default routes and resolver into the installed
# copy of 25-bat0.network. Done to a temp copy, never in place: an in-place sed
# dirties the working tree and bakes one node's address into the repo, which
# then travels to the next node as its apparent default.
#
# Each value has a named placeholder in the template rather than being matched
# by keyword. `s|^Address=.*|` was fine while there was one address; with two it
# would stamp the v6 value onto both lines. Placeholders also mean an unstamped
# file fails loudly at networkd rather than quietly carrying a stale literal.
#
# A missing value deletes its line rather than writing a blank one, which
# networkd rejects as a parse error -- taking the whole .network file down with
# it, addresses included, over a route that was meant to be optional.
stamp_or_drop() {
  local key="${1:?}" placeholder="${2:?}" value="${3-}"
  if [[ -n $value ]]; then
    sed -i -E "s|^${key}=${placeholder}\$|${key}=${value}|" "$STAMPED"
  else
    sed -i -E "/^${key}=${placeholder}\$/d" "$STAMPED"
  fi
}

# A gateway now lives in its own three-line [Route] block, so it can carry the
# explicit Metric that keeps a bench uplink's route ahead of the mesh's (see
# the comment in 25-bat0.network). stamp_or_drop handles one line; an absent
# gateway must take the whole block out, because an orphan [Route] holding
# only a Metric is exactly the kind of half-formed section networkd rejects.
stamp_or_drop_route() {
  local placeholder="${1:?}" value="${2-}"
  if [[ -n $value ]]; then
    sed -i -E "s|^Gateway=${placeholder}\$|Gateway=${value}|" "$STAMPED"
  else
    sed -i -E "/^\[Route\]\$/{N;N;/Gateway=${placeholder}/d}" "$STAMPED"
  fi
}

STAMPED=$(mktemp)
trap 'rm -f "$STAMPED"' EXIT
cp etc/systemd/network/25-bat0.network "$STAMPED"

stamp_or_drop Address IPV6_ADDRESS_PLACEHOLDER "$IPV6_ADDR"
stamp_or_drop Address IPV4_ADDRESS_PLACEHOLDER "$IPV4_ADDR"
stamp_or_drop_route IPV6_GATEWAY_PLACEHOLDER "$GATEWAY_ADDR"
stamp_or_drop_route IPV4_GATEWAY_PLACEHOLDER "$GATEWAY4_ADDR"
# The resolver is the router's dnsmasq, which is the v4 gateway. No gateway
# means no resolver to name; .local over mDNS and .mesh out of /etc/hosts carry
# node-to-node naming without it.
stamp_or_drop DNS IPV4_DNS_PLACEHOLDER "$GATEWAY4_ADDR"

# Nothing may reach a node carrying an unstamped placeholder: networkd drops the
# entire file on the first bad value, so the node would come up with no mesh
# address at all. Cheaper to fail here, next to the terminal that can fix it.
if grep -q 'PLACEHOLDER' "$STAMPED"; then
  die "unstamped placeholder left in 25-bat0.network: $(grep 'PLACEHOLDER' "$STAMPED" | tr '\n' ' ')"
fi

as_root install -D -o root -g root -m 0644 \
  "$STAMPED" /etc/systemd/network/25-bat0.network

# Apply the stamped file now rather than at the next reboot: a rerun of this
# installer on a live node must fix its routes live, or a bad route sits until
# someone remembers to reboot. reconfigure is not a link bounce -- addresses
# and routes are reapplied in place, so an install run over SSH survives it.
# Tolerated failures: the very first install has no bat0 netdev yet, and the
# route lands at boot as normal.
as_root networkctl reload 2>/dev/null || true
as_root networkctl reconfigure bat0 2>/dev/null || true

# DNS coexistence with a bench uplink.
#
# 25-bat0.network claimed Domains=~. -- the catch-all routing domain -- when
# its resolvers were unreachable v6 literals, and with the mesh down every
# lookup went there to die while a healthy Ethernet uplink sat right beside
# the node. bat0 carries a plain per-link resolver now, no monopoly, but the
# Ethernet stamps below stay: they are what lets a bench uplink answer for
# every name whichever links are up, and they cost nothing when the mesh
# answers instead.
#
# The remedy is to stamp ~. onto the NetworkManager Ethernet profiles too.
# With more than one ~. link, resolved queries them all and the first good
# answer wins: bench Ethernet answers while the mesh is down, the mesh answers
# in the field where there is no Ethernet, and with both up the race is
# harmless -- public names resolve the same either way. Profiles that carry no
# DNS server (the lidar links) contribute no DNS scope and are unaffected.
#
# This loop covers the profiles that exist right now, live, without waiting
# for a reconnect. Profiles minted later -- a swapped USB dongle mints a fresh
# "Wired connection N" -- are caught at activation by the dispatcher hook
# installed above (etc/NetworkManager/dispatcher.d/90-dns-mesh-coexist), which
# is what makes the fix stick across hardware swaps.
if command -v nmcli >/dev/null; then
  while IFS=: read -r con_name con_type; do
    [[ $con_type == *ethernet* ]] || continue
    # Per address family, tolerating rejection: a method like ignore or
    # disabled refuses dns-search outright (the lidar links do), and rightly
    # so -- that family carries no DNS to coexist with. The refusal IS the
    # skip. A family with no DNS servers accepts the stamp but resolved
    # creates no scope for it, so it is inert there too.
    stamped=""
    as_root nmcli con mod "$con_name" ipv4.dns-search '~.' 2>/dev/null && stamped=1
    as_root nmcli con mod "$con_name" ipv6.dns-search '~.' 2>/dev/null && stamped=1
    if [[ -n $stamped ]]; then
      log "stamped DNS routing domain '~.' onto '${con_name}'"
    else
      log "skipped '${con_name}': no DNS-capable address family"
    fi
  done < <(nmcli -t -f NAME,TYPE con show)
  # reapply, not `con up`: no link flap, so an install run over that very
  # interface (SSH) survives it.
  while IFS=: read -r dev dev_type state; do
    [[ $dev_type == ethernet && $state == connected ]] || continue
    as_root nmcli device reapply "$dev" >/dev/null 2>&1 || true
  done < <(nmcli -t -f DEVICE,TYPE,STATE device status)
fi

# Stamp the same gateway address into the chrony drop-in, for the same reason:
# derived, never written down, so a ULA_PREFIX override moves the time source
# along with everything else.
#
# With no gateway there is no authoritative clock, so the drop-in is removed
# rather than left pointing at a placeholder. chrony then free-runs and `soak`
# refuses to log, which is the correct outcome -- unjoinable timestamps are
# worse than no timestamps, and the operator is told why.
if [[ -n $GATEWAY_ADDR ]]; then
  CHRONY_STAMPED=$(mktemp)
  sed -E "s|^server GATEWAY_ADDRESS_PLACEHOLDER|server ${GATEWAY_ADDR}|" \
    etc/chrony/conf.d/halow-mesh.conf >"$CHRONY_STAMPED"
  as_root install -D -o root -g root -m 0644 \
    "$CHRONY_STAMPED" /etc/chrony/conf.d/halow-mesh.conf
  rm -f "$CHRONY_STAMPED"
  log "chrony will follow ${GATEWAY_NAME} at ${GATEWAY_ADDR}"
else
  as_root rm -f /etc/chrony/conf.d/halow-mesh.conf
  warn "no gateway: this node has no time source, and 'soak' will refuse to run"
fi

# systemd-timesyncd and chrony both want to discipline the clock and will fight
# over it. Same class of collision as avahi against systemd-resolved below, and
# the same remedy. Masked rather than disabled so a package upgrade cannot
# quietly re-enable it on a node in the field.
as_root systemctl mask --now systemd-timesyncd.service 2>/dev/null || true

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
log "wrote $(merge_hosts ./etc/bat-hosts "$ULA_PREFIX") node(s) into /etc/hosts as <name>.mesh"

# Reload and enable. halow0-ibss has no [Install]; it is pulled by the udev
# rule and by halow0-attach's Requires=.
as_root systemctl daemon-reload
as_root udevadm control --reload
as_root systemctl enable systemd-networkd systemd-resolved halow0-attach.service
as_root systemctl enable chrony.service 2>/dev/null ||
  as_root systemctl enable chronyd.service 2>/dev/null ||
  warn "could not enable the chrony unit; check its name on this distro"

# fake-hwclock writes the system time to disk periodically and restores it at
# boot. The Orin Nano has no working RTC and comes up at the Unix epoch, which
# turns chrony's first correction into a 56-year leap; this makes it come up at
# "a few minutes ago" instead. An effectively stale-but-sane software RTC.
#
# Saved now so the very next boot already benefits, rather than waiting for the
# first periodic save.
if command -v fake-hwclock >/dev/null; then
  as_root systemctl enable fake-hwclock.service 2>/dev/null || true
  as_root fake-hwclock save 2>/dev/null || true
else
  warn "fake-hwclock not installed; this node will boot to 1970 (run ./build_dependencies.sh)"
fi
