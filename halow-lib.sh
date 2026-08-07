# shellcheck shell=bash
#
# halow-lib.sh -- shared helpers for the HaLow bring-up and diagnostics tooling.
#
# Sourced by batman_oracle.sh and install_network_stack.sh; not executable on
# its own.
#
# Everything here was duplicated across the scripts before. That mattered beyond
# tidiness: the pingif selection and the RSSI sampler existed in two copies
# each, so a fix to either had to be made twice, and one that was made once
# drifted. The installer had a third copy of the identity helpers.
#
# Four groups of helpers:
#
#   identity   which node this is, and what address it should hold
#   remote     run a command on a node, which may or may not be this machine
#   sampling   read link quality out of iw/batctl/morse_cli
#   hosts      the /etc/hosts block derived from the node roster
#
# Identity comes from the radio MAC looked up in bat-hosts, so the same files
# ship to every node unchanged and nothing has to be edited per device. Falls
# back to the system hostname, then to whatever the caller defaulted to.
#
# Addresses are then derived, not stored: the fleet-wide ULA prefix plus an
# EUI-64 suffix from each radio's MAC. One table drives the whole roster.

# --------------------------------------------------------------------------
# Logging
# --------------------------------------------------------------------------

# Each script sets LOG_TAG after sourcing; the default keeps output sane if one
# forgets. Resolved at call time, so the assignment order does not matter.
LOG_TAG=${LOG_TAG:-halow}

log() { printf '[%s] %s\n' "$LOG_TAG" "$*" >&2; }
warn() { printf '[%s] warning: %s\n' "$LOG_TAG" "$*" >&2; }
die() {
  printf '[%s] ERROR: %s\n' "$LOG_TAG" "$*" >&2
  exit 1
}

# --------------------------------------------------------------------------
# Preflight
# --------------------------------------------------------------------------

as_root() { if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi; }

# require_root [why] -- the optional argument explains what needs the
# privilege, worth having where it is not obvious (ping interval, iw access).
require_root() {
  [[ $EUID -eq 0 ]] || die "must run as root${1:+ ($1)}"
}

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
#
# Returns empty on a machine with no Morse radio at all -- which is the normal
# case for the laptop driving the oracle, not an error.
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
# detection finds nothing (card unplugged, morse.ko not loaded, or we are on
# the laptop and the interface only exists on the far end of an ssh hop).
# Callers still let IFACE override.
default_iface() {
  local i
  i=$(morse_iface)
  printf '%s' "${i:-halow0}"
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
  local iface="${1?missing \'iface\' argument, aborting}"
  local link
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
    mac=$(cat "/sys/class/net/$iface/address" 2>/dev/null || true)
  printf '%s' "$mac"
}

# node_name <iface> [<bat_hosts_file>] -- this node's name.
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

# --------------------------------------------------------------------------
# Fleet roster
# --------------------------------------------------------------------------

# fleet_nodes <bat_hosts> -- every node name in the roster, one per line.
fleet_nodes() {
  local bat_hosts="${1?missing \'bat_hosts\' argument, aborting}"
  [[ -f $bat_hosts ]] || return 0
  awk '/^[[:space:]]*(#|$)/ {next} {sub(/\.lan$/, "", $2); print $2}' "$bat_hosts"
}

# node_mac <name> <bat_hosts> -- the radio MAC for a named node.
node_mac() {
  local name="${1?missing \'name\' argument, aborting}"
  local bat_hosts="${2?missing \'bat_hosts\' argument, aborting}"
  [[ -f $bat_hosts ]] || return 0
  awk -v n="$name" '
    /^[[:space:]]*(#|$)/ {next}
    { sub(/\.lan$/, "", $2); if ($2 == n) { print tolower($1); exit } }' "$bat_hosts"
}

# node_mesh_addr <name> <bat_hosts> <ula_prefix> -- a node's mesh address,
# derived rather than looked up. Everything needed is here: the roster holds
# every radio MAC, the prefix is fleet-wide, EUI-64 is deterministic.
#
# This is what lets the laptop address the fleet without running the installer
# or holding a copy of anyone's /etc/hosts.
node_mesh_addr() {
  local name="${1?missing \'name\' argument, aborting}"
  local bat_hosts="${2?missing \'bat_hosts\' argument, aborting}"
  local prefix="${3?missing \'ula_prefix\' argument, aborting}"
  local mac
  mac=$(node_mac "$name" "$bat_hosts")
  [[ -n $mac ]] || return 0
  printf '%s:%s' "$prefix" "$(eui64_from_mac "$mac")"
}

# --------------------------------------------------------------------------
# Remote execution
# --------------------------------------------------------------------------
#
# The oracle runs on a laptop that is not a mesh node: no Morse radio, no bat0,
# and reaching the mesh only through the router's Ethernet. Every reading it
# wants -- RSSI, station counters, originators, and crucially the ping itself
# -- has to be taken ON a node, or it measures the laptop's Ethernet hop
# instead of the radio link under test.
#
# So there is exactly one abstraction: run this on node N. Executing locally is
# the degenerate case where N is this machine, which is what happens when the
# oracle is run on a Jetson.

SSH_USER=${SSH_USER:-}
SSH_OPTS=${SSH_OPTS:-}

# ssh_control_dir -- multiplexing socket directory. A `walk` takes one probe
# per second and a probe is one ssh invocation; without ControlMaster each
# would pay a full handshake and the sampling period would be dominated by key
# exchange rather than by the interval that was asked for.
SSH_CONTROL_DIR=${SSH_CONTROL_DIR:-${TMPDIR:-/tmp}/halow-oracle-ssh.$$}

ssh_setup() {
  mkdir -p "$SSH_CONTROL_DIR"
  chmod 700 "$SSH_CONTROL_DIR"
}

ssh_teardown() {
  [[ -d $SSH_CONTROL_DIR ]] || return 0
  local s
  for s in "$SSH_CONTROL_DIR"/*; do
    [[ -S $s ]] || continue
    ssh -o ControlPath="$s" -O exit placeholder >/dev/null 2>&1 || true
  done
  rm -rf "$SSH_CONTROL_DIR"
}

# is_self <name> <bat_hosts> -- is the named node this machine?
#
# Checked by radio MAC first, which is authoritative, then by hostname. The MAC
# test is what makes this correct on a node whose hostname has not been set yet
# (before the installer's first run) and the hostname test is what makes it
# work on the router, where there is no Morse netdev to read.
is_self() {
  local name="${1?missing \'name\' argument, aborting}"
  local bat_hosts="${2:-}"
  local iface mac want

  iface=$(morse_iface)
  if [[ -n $iface && -n $bat_hosts ]]; then
    mac=$(iface_mac "$iface")
    want=$(node_mac "$name" "$bat_hosts")
    [[ -n $mac && -n $want && ${mac,,} == "$want" ]] && return 0
  fi

  [[ $(hostname 2>/dev/null || true) == "$name" ]]
}

# node_target <name> <bat_hosts> <ula_prefix> -- the ssh destination for a node.
#
# Prefers the derived mesh address over the name: it needs no resolver on
# either end, which matters because the laptop has not run the installer and
# the router has no systemd-resolved to answer .local at all. Falls back to the
# bare name for a node not in the roster.
#
# The address is returned UNBRACKETED. Brackets are a URI convention -- scp and
# sftp want them -- but plain ssh parses its destination itself and treats
# `[fd..]` as a literal hostname, which then fails to resolve. ping and iperf3
# likewise take a bare IPv6 literal.
node_target() {
  local name="${1?missing \'name\' argument, aborting}"
  local bat_hosts="${2:-}"
  local prefix="${3:-}"
  local addr=

  if [[ -n $bat_hosts && -n $prefix ]]; then
    addr=$(node_mesh_addr "$name" "$bat_hosts" "$prefix")
  fi

  printf '%s' "${addr:-$name}"
}

# node_run <name> <bat_hosts> <ula_prefix> <command...> -- run a command on a
# node. Locally when that node is us, over ssh otherwise.
#
# The command is passed to `sh -c` on the far end, so it must be POSIX sh: the
# router runs busybox ash and has no bash.
node_run() {
  local name="${1?missing \'name\' argument, aborting}"
  local bat_hosts="${2:-}"
  local prefix="${3:-}"
  shift 3

  if is_self "$name" "$bat_hosts"; then
    sh -c "$*"
    return $?
  fi

  local target dest
  target=$(node_target "$name" "$bat_hosts" "$prefix")
  dest="${SSH_USER:+$SSH_USER@}$target"

  ssh_setup
  # SSH_OPTS is deliberately word-split so a caller can pass several options.
  # shellcheck disable=SC2086
  ssh -n -o BatchMode=yes \
    -o ControlMaster=auto \
    -o ControlPath="$SSH_CONTROL_DIR/%C" \
    -o ControlPersist=60 \
    -o ConnectTimeout=5 \
    -o StrictHostKeyChecking=accept-new \
    $SSH_OPTS "$dest" "$*"
}

# --------------------------------------------------------------------------
# Probing
# --------------------------------------------------------------------------

# probe_script <iface> <meshif> <peer> <ping_timeout> -- the POSIX sh snippet
# that gathers one full sample.
#
# Everything is collected in ONE round trip and parsed on this side. The
# alternative -- one ssh per reading -- costs five or six round trips per
# sample, which at a 1 s walk interval is most of the interval, and worse, it
# smears the readings across it: the RSSI would be from a different instant
# than the ping that is supposed to explain it.
#
# Sections are delimited rather than parsed remotely, so the raw text is
# available locally for the logs. Every command is allowed to fail: a peer that
# has gone away must produce an empty section, not a failed probe.
probe_script() {
  local iface="${1?missing \'iface\' argument, aborting}"
  local meshif="${2?missing \'meshif\' argument, aborting}"
  local peer="${3:-}"
  local ping_timeout="${4:-1}"

  cat <<EOF
# priv -- run a reader with privilege when we can get it without asking.
#
# batctl refuses outright without root, and iw's survey dump reports noise and
# channel-busy only to root: unprivileged they come back empty, which looks
# exactly like a driver that does not report them. Both were silently blank in
# every row until this was added.
#
# -n is the whole point: it fails immediately instead of prompting. A probe
# runs once a second inside a walk and over BatchMode ssh, so a password prompt
# would hang the sampler rather than ask anyone anything.
#
# Falls back to running unprivileged, so a node with no sudo rights keeps
# working exactly as it did before rather than losing the readings that never
# needed root -- station dump among them.
priv() {
  if [ "\$(id -u)" = 0 ]; then
    "\$@"
  else
    sudo -n "\$@" 2>/dev/null || "\$@"
  fi
}
echo "==PROBE_TS=="
date +%s.%N 2>/dev/null || date +%s
echo "==STATION=="
iw dev $iface station dump 2>/dev/null || true
echo "==SURVEY=="
priv iw dev $iface survey dump 2>/dev/null || true
echo "==LINKINFO=="
iw dev $iface info 2>/dev/null || true
echo "==ORIGINATORS=="
priv batctl meshif $meshif originators 2>/dev/null || true
echo "==NEIGHBORS=="
priv batctl meshif $meshif neighbors 2>/dev/null || true
echo "==GATEWAYS=="
priv batctl meshif $meshif gwl 2>/dev/null || true
echo "==BATSTATS=="
priv batctl meshif $meshif statistics 2>/dev/null || true
echo "==CHRONY=="
chronyc tracking 2>/dev/null || true
echo "==PING=="
if [ -n "$peer" ]; then
  pingif=$meshif
  ip link show $meshif >/dev/null 2>&1 || pingif=$iface
  ping -I "\$pingif" -c 1 -W $ping_timeout $peer 2>&1 || true
fi
echo "==END=="
EOF
}

# probe_node <name> <bat_hosts> <ula_prefix> <iface> <meshif> <peer> <timeout>
# -- one full sample from a node, as raw delimited text on stdout.
probe_node() {
  local name=$1 bat_hosts=$2 prefix=$3 iface=$4 meshif=$5 peer=$6 timeout=$7
  node_run "$name" "$bat_hosts" "$prefix" \
    "$(probe_script "$iface" "$meshif" "$peer" "$timeout")" 2>/dev/null || true
}

# --------------------------------------------------------------------------
# Parsing
# --------------------------------------------------------------------------

# probe_section <name> -- extract one ==NAME== section from a probe on stdin.
probe_section() {
  awk -v want="==$1==" '
    $0 ~ /^==[A-Z_]+==$/ { on = ($0 == want); next }
    on { print }
  '
}

# parse_station [peer_mac] -- flatten `iw station dump` into key=value lines.
#
# An empty peer_mac takes the first station listed: what you want with exactly
# two nodes up, and arbitrary with more, which is why walk and soak both name
# the peer explicitly once the fleet is bigger than a pair.
#
# The fields are wider than the old walk recorded. Retries, failures and drops
# are the ones that move first: at range a link degrades by retrying long
# before it starts losing pings, so a walk that logs only RSSI and reachability
# throws away the early warning it was walked to find.
parse_station() {
  local peer_mac=${1:-}
  awk -v want="${peer_mac,,}" '
    function emit() {
      if (!seen) return
      print "station_mac=" mac
      print "rssi=" sig
      print "rssi_avg=" sigavg
      print "tx_bitrate_mbps=" txrate
      print "tx_mcs=" txmcs
      print "tx_nss=" txnss
      print "rx_bitrate_mbps=" rxrate
      print "rx_mcs=" rxmcs
      print "tx_packets=" txpkt
      print "tx_retries=" txretry
      print "tx_failed=" txfail
      print "rx_packets=" rxpkt
      print "rx_drop_misc=" rxdrop
      print "tx_bytes=" txbytes
      print "rx_bytes=" rxbytes
      print "expected_tput_mbps=" etput
      print "inactive_ms=" inact
      print "connected_s=" conn
      print "beacon_loss=" bloss
      print "beacon_signal_avg=" bsig
      done_ = 1
    }
    function reset() {
      mac = sig = sigavg = txrate = txmcs = txnss = rxrate = rxmcs = ""
      txpkt = txretry = txfail = rxpkt = rxdrop = txbytes = rxbytes = ""
      etput = inact = conn = bloss = bsig = ""
    }
    BEGIN { reset(); seen = 0; done_ = 0 }
    /^Station/ {
      if (seen && (want == "" || matched)) { emit(); if (done_) exit }
      reset()
      mac = tolower($2)
      matched = (want != "" && mac == want)
      seen = (want == "" || matched)
      next
    }
    !seen { next }
    # Anchored, every one of them. `iw` indents each field and several are
    # prefixes of others: an unanchored /signal avg:/ also matches the
    # `beacon signal avg:` line, which then overwrites the reading with the
    # wrong field offset -- silently, and only on drivers that report beacon
    # statistics at all.
    /^[[:space:]]*signal:/            { sig = $2 }
    /^[[:space:]]*signal avg:/        { sigavg = $3 }
    /^[[:space:]]*beacon signal avg:/ { bsig = $4 }
    /^[[:space:]]*beacon loss:/       { bloss = $3 }
    /^[[:space:]]*tx bitrate:/        { txrate = $3
                                        for (i = 1; i <= NF; i++) {
                                          if ($i == "MCS") txmcs = $(i+1)
                                          if ($i == "NSS") txnss = $(i+1)
                                        } }
    /^[[:space:]]*rx bitrate:/        { rxrate = $3
                                        for (i = 1; i <= NF; i++)
                                          if ($i == "MCS") rxmcs = $(i+1) }
    /^[[:space:]]*tx packets:/        { txpkt = $3 }
    /^[[:space:]]*tx retries:/        { txretry = $3 }
    /^[[:space:]]*tx failed:/         { txfail = $3 }
    /^[[:space:]]*rx packets:/        { rxpkt = $3 }
    /^[[:space:]]*rx drop misc:/      { rxdrop = $4 }
    /^[[:space:]]*tx bytes:/          { txbytes = $3 }
    /^[[:space:]]*rx bytes:/          { rxbytes = $3 }
    /^[[:space:]]*inactive time:/     { inact = $3 }
    /^[[:space:]]*connected time:/    { conn = $3 }
    # `expected throughput:  1.234Mbps` -- one token, unit attached.
    /^[[:space:]]*expected throughput:/ { etput = $3; sub(/Mbps$/, "", etput) }
    END { if (!done_) emit() }
  '
}

# parse_survey -- the in-use channel only, as key=value lines.
#
# Channel busy time is the reading the old walk had no equivalent of and the
# one that most changes how a bad result is read. At 1 MHz there is very little
# airtime to go around, so "the link got worse" and "something else started
# talking" look identical in RSSI and are trivially distinguishable here.
parse_survey() {
  awk '
    /^Survey data/ { inuse = 0; act = busy = rx = tx = noise = freq = ""; next }
    /\[in use\]/   { inuse = 1; freq = $2 }
    !inuse { next }
    /noise:/                  { noise = $2 }
    /channel active time:/    { act = $4 }
    /channel busy time:/      { busy = $4 }
    /channel receive time:/   { rx = $4 }
    /channel transmit time:/  { tx = $4 }
    END {
      print "freq_mhz=" freq
      print "noise_dbm=" noise
      print "survey_active_ms=" act
      print "survey_busy_ms=" busy
      print "survey_rx_ms=" rx
      print "survey_tx_ms=" tx
      if (act + 0 > 0) printf "busy_pct=%.2f\n", 100 * busy / act
      else print "busy_pct="
    }
  '
}

# parse_originators [peer] -- best-route TQ, next hop and originator count.
#
# `batctl originators` prints one line per candidate route and marks the
# selected one with a leading `*`. Only the marked line is the route in use;
# the others are alternates the algorithm is holding in reserve, and averaging
# over them (or taking the maximum, as tq_best did) reports a path that no
# traffic is taking.
#
# With a named peer this reports that peer's route. Without one it reports the
# best available, which is the same thing only while exactly two nodes are up.
# parse_originators [<key>[,<key>...]] -- the best route to a peer.
#
# The key is a COMMA-SEPARATED SET, because the same peer appears in the table
# under two different spellings and which one you get is not knowable from
# here. batctl substitutes names out of /etc/bat-hosts when it has them and
# prints raw hex when it does not, so a caller that knows only the MAC misses
# every row of a substituted table -- silently, as an empty tq rather than an
# error. Pass both the MAC and the roster name and let whichever exists match.
#
# An empty key means "the best route to anywhere", which is what `status` wants
# and is only equivalent to a named peer when the fleet is a pair.
parse_originators() {
  local peer=${1:-}
  awk -v want="${peer,,}" '
    BEGIN {
      nw = split(want, wl, /,/)
      for (wi = 1; wi <= nw; wi++)
        if (wl[wi] != "") WANT[wl[wi]] = 1
    }
    function tqof(line,   v) {
      if (match(line, /\([ ]*[0-9]+\)/)) {
        v = substr(line, RSTART + 1, RLENGTH - 2)
        gsub(/ /, "", v)
        return v + 0
      }
      return -1
    }
    /^[[:space:]]*(Originator|\[|B\.A\.T\.M\.A\.N\.)/ { next }
    {
      line = $0
      best = (line ~ /^[[:space:]]*\*/)
      sub(/^[[:space:]]*\*?[[:space:]]*/, "", line)
      n = split(line, f, /[[:space:]]+/)
      if (n < 4) next
      orig = tolower(f[1])
      # batctl prints last-seen as `0.320s`; strip the unit so the column is
      # numeric and can be thresholded offline.
      lastseen = f[2]; sub(/s$/, "", lastseen)
      tq = tqof(line)
      if (tq < 0) next
      # the next hop is the first field after the (tq) column
      for (i = 3; i <= n; i++) if (f[i] ~ /^\(/ || f[i] ~ /\)$/) { nh = f[i+1]; break }
      if (best) {
        count++
        if (want == "" || (orig in WANT)) {
          if (want != "" || tq > bt) { bt = tq; bnh = nh; bls = lastseen; bo = orig }
        }
      }
    }
    END {
      print "tq=" (bt ? bt : "")
      print "nexthop=" bnh
      print "originator=" bo
      print "last_seen_s=" bls
      print "originator_count=" count + 0
      # A next hop equal to the originator is a direct link; anything else is
      # relayed. batctl does not print a hop count, and this is the only hop
      # information available without walking the whole table.
      if (bo != "" && bnh != "") print "direct=" (tolower(bnh) == bo ? 1 : 0)
      else print "direct="
    }
  '
}

# parse_ping -- rtt and reachability from a single `ping -c 1`.
parse_ping() {
  awk '
    BEGIN { ok = 0; rtt = "" }
    /bytes from/ && /time=/ {
      ok = 1
      split($0, a, "time=")
      split(a[2], b, " ")
      rtt = b[1]
    }
    END { print "ping_ok=" ok; print "rtt_ms=" rtt }
  '
}

# parse_chrony -- clock health, which bounds how well this node's timestamps
# line up with any other node's. Logged as data rather than only gated on,
# because a run whose sync degraded partway is still usable if you can see
# where.
parse_chrony() {
  awk '
    /Last offset/ { lo = $4 }
    /RMS offset/  { rms = $4 }
    /Frequency/   { freq = $3 }
    /Skew/        { skew = $4 }
    /Root delay/  { rd = $4 }
    /Stratum/     { st = $3 }
    END {
      print "clock_last_offset_s=" lo
      print "clock_rms_offset_s=" rms
      print "clock_freq_ppm=" freq
      print "clock_skew_ppm=" skew
      print "clock_root_delay_s=" rd
      print "clock_stratum=" st
    }
  '
}

# --------------------------------------------------------------------------
# Local-only sampling (used by `status` against this machine)
# --------------------------------------------------------------------------

# mesh_usable <meshif> -- true only when the mesh interface can actually carry
# traffic: present, UP, addressed, and with at least one hard interface in it.
#
# Existence alone is not enough, and assuming it was cost us a field session.
# A bat0 left behind by a teardown -- down, and formerly still holding its
# address -- made an existence test silently route every probe into a dead
# interface and report a link that was never tried.
mesh_usable() {
  local meshif=$1

  ip link show "$meshif" >/dev/null 2>&1 || return 1
  ip link show "$meshif" 2>/dev/null | head -1 | grep -q '[<,]UP[,>]' || return 1
  ip -6 addr show dev "$meshif" 2>/dev/null | grep -q 'inet6 fd' || return 1

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
# up, leaving two -- stale entries, shadowing nothing, impossible to spot.
HOSTS_BEGIN="# BEGIN halow-batman"
HOSTS_END="# END halow-batman"

# hosts_block <bat_hosts> <ula_prefix> -- the fleet's /etc/hosts entries.
#
# Every node's address is derivable here, not just this one's, so one table
# generates the whole roster with nothing to keep in sync by hand.
#
# The names are <name>.mesh plus the bare <name> -- NOT <name>.local. RFC 6762
# reserves .local for mDNS, and since nsswitch reads files before resolve, a
# static .local entry would permanently shadow mDNS for that name: a stale
# entry would win forever and the mDNS path would never be exercised. Keeping
# the suffixes apart means a failure says which layer broke -- .mesh failing is
# the roster or the address derivation, .local failing is mDNS/resolved/NSS,
# both failing is the mesh itself.
#
# Emitted separately from merge_hosts so it can be printed for the two machines
# that never run the installer: the OpenWrt router, which has no systemd at
# all, and the laptop driving the oracle.
hosts_block() {
  local bat_hosts="${1?missing \'bat_hosts\' argument, aborting}"
  local prefix="${2?missing \'ula_prefix\' argument, aborting}"
  local mac name

  echo "$HOSTS_BEGIN"
  while read -r mac name; do
    # Tolerate a .lan suffix left in a node's hand-edited bat-hosts from the
    # retired IPv4 scheme; the shipped table no longer carries one.
    name=${name%.lan}
    printf '%s:%s\t%s.mesh\t%s\n' \
      "$prefix" "$(eui64_from_mac "$mac")" "$name" "$name"
  done < <(grep -vE '^[[:space:]]*(#|$)' "$bat_hosts")
  echo "$HOSTS_END"
}

# merge_hosts <bat_hosts> <ula_prefix> -- replace the marked block in
# /etc/hosts with the fleet roster.
#
# /etc/hosts is never overwritten -- only the marked block is replaced, so
# localhost and anything else the distro or the operator put there survives,
# and repeated runs are idempotent.
merge_hosts() {
  local bat_hosts="${1?missing \'bat_hosts\' argument, aborting}"
  local prefix="${2?missing \'ula_prefix\' argument, aborting}"
  local tmp

  [[ -f $bat_hosts && -f /etc/hosts ]] || return 0

  tmp=$(mktemp)
  sed "\|^${HOSTS_BEGIN}\$|,\|^${HOSTS_END}\$|d" /etc/hosts >"$tmp"
  hosts_block "$bat_hosts" "$prefix" >>"$tmp"

  as_root install -o root -g root -m 0644 "$tmp" /etc/hosts
  rm -f "$tmp"

  grep -cvE '^[[:space:]]*(#|$)' "$bat_hosts"
}
