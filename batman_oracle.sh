#!/usr/bin/env bash
#
# batman_oracle.sh -- ask the mesh how it is doing.
#
# One diagnostics tool. It replaces halow-measure.sh (`at` and `walk`) and the
# `status` subcommand of halow-batman.sh, which were separate programs sampling
# the same radio through three copies of the same parsers.
#
# halow-ibss.sh and halow-batman.sh are gone with them. They were a manual
# bring-up harness from before the systemd units existed, still addressing the
# retired IPv4 scheme and reading roster files that are no longer in the repo.
# install_network_stack.sh does that job now; `git log` has them if needed.
#
#   status                   one-shot health check of the whole fleet
#   at <distance_m> [note]   one careful passive measurement at a surveyed distance
#   tp <distance_m> [note]   an active throughput run at a surveyed distance
#   walk                     continuous trace while a node moves
#   soak                     unattended long-run logging, for offline analysis
#   hosts                    print the fleet's /etc/hosts block
#
# `at` and `tp` are split on the passive/active line. `at` observes the link
# without changing it; `tp` saturates it. Their results go to different CSVs so
# that the two are never averaged together.
#
# THE ORACLE IS A REMOTE CONTROL HEAD, NOT A NODE.
#
# It is normally run from a laptop plugged into the router's Ethernet, which
# has no HaLow radio and no bat0 of its own. So every reading -- RSSI, the
# station counters, the originator table, and above all the ping -- is taken
# ON a node over ssh. A ping issued by the laptop would traverse Ethernet and
# the router before touching the radio, and would report a number that says
# nothing about the hop under test.
#
# Running it on a Jetson is the same code path with the ssh hop elided; NODE
# defaults to whichever machine it is running on when that machine has a radio.
#
#   ./batman_oracle.sh status
#   NODE=olo PEER=wazza BW_MHZ=1 HEIGHT_M=4 ./batman_oracle.sh at 750 "clear LOS"
#   NODE=olo PEER=wazza BW_MHZ=1 HEIGHT_M=4 ./batman_oracle.sh tp 750
#   NODE=olo PEER=wazza BW_MHZ=1 HEIGHT_M=4 ./batman_oracle.sh walk
#   NODE=olo ./batman_oracle.sh soak
#
# Bandwidth changes need BOTH ends reconfigured, so a sweep means walking back.
# Plan positions around that: do every bandwidth at one distance before moving.

set -uo pipefail
# Deliberately no `set -e`. A peer going down mid-run must not kill the tool
# during a field session; failures are tolerated per-command and recorded as
# data, because "no peer at this position" is usually the result being sought.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=halow-lib.sh
source "$ROOT/halow-lib.sh"
# Read by log()/warn()/die() in the library, not here.
# shellcheck disable=SC2034
LOG_TAG=oracle

# --------------------------------------------------------------------------
# Configuration -- shared by every mode
# --------------------------------------------------------------------------

# The node roster and the fleet-wide prefix. Between them every node's address
# is derivable, which is what lets this run on a laptop that has never run the
# installer and holds no /etc/hosts entries for the mesh.
BAT_HOSTS=${BAT_HOSTS:-$ROOT/etc/bat-hosts}
ULA_PREFIX=${ULA_PREFIX:-fdc7:37f3:e24a:0}

# Which node to measure FROM. Defaults to this machine when it has a Morse
# radio; on the laptop there is no sensible default and it must be named.
NODE=${NODE:-}

# Which node to measure TO. A roster name, resolved to a mesh address here so
# neither end needs a working resolver.
PEER=${PEER:-}

# Interface names as seen ON the node, not on this machine.
IFACE=${IFACE:-halow0}
MESHIF=${MESHIF:-bat0}

# Restrict the station reading to one peer's radio MAC. Defaults to PEER's MAC
# from the roster; empty means "first station listed", which is what you want
# with exactly two nodes up and arbitrary with more.
PEER_MAC=${PEER_MAC:-}

# Seconds between radio reads.
SAMPLE_INTERVAL=${SAMPLE_INTERVAL:-1}

# Recorded verbatim, not measured. The driver reports S1G channels as their
# 5 GHz equivalents so the real figure is not readable, and antenna height
# dominates path loss -- a row without it cannot be compared against any other.
BW_MHZ=${BW_MHZ:-}
HEIGHT_M=${HEIGHT_M:-}

LOGDIR=${LOGDIR:-$ROOT/oracle-logs}

# Per-probe ping timeout, seconds. Keep it under SAMPLE_INTERVAL.
PING_TIMEOUT=${PING_TIMEOUT:-1}

# --------------------------------------------------------------------------
# Configuration -- `at`
# --------------------------------------------------------------------------

# RSSI fluctuates several dB outdoors -- a single reading is noise, not a
# measurement. Sample across a window and keep the spread.
SAMPLES=${SAMPLES:-30}

PING_COUNT=${PING_COUNT:-100}
PING_INTERVAL=${PING_INTERVAL:-0.2}

# Throughput needs `iperf3 -s` running on the peer. Off by default: at 1 MHz a
# burst is a large fraction of the whole channel, and RSSI plus loss already
# answers "does this work".
IPERF=${IPERF:-0}
IPERF_TIME=${IPERF_TIME:-10}

# --------------------------------------------------------------------------
# Configuration -- `tp`
# --------------------------------------------------------------------------

# Seconds per direction.
TP_TIME=${TP_TIME:-10}

# Seconds discarded from the start of each direction (iperf3 -O). At 1 MHz the
# rate control takes a moment to settle and the first seconds understate a link
# that is actually fine.
TP_OMIT=${TP_OMIT:-2}

# Test both directions. Asymmetry is common and worth catching: the two ends
# have different noise floors and, once the antennas are at different heights,
# genuinely different links.
TP_REVERSE=${TP_REVERSE:-1}

# Start a one-shot `iperf3 -s -1` on the peer for the duration, rather than
# requiring one be left running. The -1 form exits after a single client, so
# there is nothing to clean up and nothing left listening on a field node.
# Set 0 if you are running your own server on the peer.
TP_AUTOSERVER=${TP_AUTOSERVER:-1}

# --------------------------------------------------------------------------
# Configuration -- `walk`
# --------------------------------------------------------------------------

# Consecutive failed probes before calling the link down. One dropped ping at
# range is normal; several in a row is a cutoff. Raising this makes the tool
# slower to declare loss but less prone to calling it early on a deep fade.
LOSS_HOLD=${LOSS_HOLD:-5}

# Stop after this many seconds of continuous loss. 0 runs until Ctrl-C, which
# is what you want if the walker is expected to come back into range.
EXIT_AFTER_LOSS=${EXIT_AFTER_LOSS:-0}

# --------------------------------------------------------------------------
# Configuration -- `soak`
# --------------------------------------------------------------------------

# Cross-node timestamp joins are meaningless if the clocks disagree, so soak
# refuses to log until chrony says the node is synced. See docs/MONITORING.md.
REQUIRE_SYNC=${REQUIRE_SYNC:-1}
SYNC_MAX_OFFSET=${SYNC_MAX_OFFSET:-0.05}
SYNC_TIMEOUT=${SYNC_TIMEOUT:-120}

# Which nodes to probe. Empty means the whole roster except NODE itself.
SOAK_PEERS=${SOAK_PEERS:-}

# Throughput bursts during a soak. Off by default and it should stay off unless
# throughput is the question being asked: at 1 MHz the channel carries a few
# hundred kbit/s, so a burst does not perturb the measurement, it IS the
# measurement, and every passive number taken during one is about a saturated
# link rather than the deployment.
SOAK_THROUGHPUT=${SOAK_THROUGHPUT:-0}
TP_INTERVAL=${TP_INTERVAL:-600}
TP_DURATION=${TP_DURATION:-10}

MAX_FILE_MB=${MAX_FILE_MB:-100}

# --------------------------------------------------------------------------
# Plumbing
# --------------------------------------------------------------------------

usage() {
  cat >&2 <<-EOF
	usage: $0 status
	       NODE=<node> PEER=<node> $0 at <distance_m> [note]
	       NODE=<node> PEER=<node> $0 tp <distance_m> [note]
	       NODE=<node> PEER=<node> $0 walk
	       NODE=<node> $0 soak
	       $0 hosts

	  NODE   node to measure from (default: this machine, if it has a radio)
	  PEER   node to measure to
	EOF
  exit 2
}

# One probe's worth of parsed values, keyed by name.
declare -A P

# kv_load -- read key=value lines from stdin into P, clearing it first.
kv_load() {
  local k v
  P=()
  while IFS='=' read -r k v; do
    [[ -n $k ]] && P[$k]=$v
  done
}

# p <key> -- a probe value, or empty.
p() { printf '%s' "${P[${1}]:-}"; }

run_on_node() { node_run "$NODE" "$BAT_HOSTS" "$ULA_PREFIX" "$@"; }

# resolve_node -- work out NODE, and fail early and clearly if we cannot.
resolve_node() {
  if [[ -z $NODE ]]; then
    local iface
    iface=$(morse_iface)
    [[ -n $iface ]] ||
      die "no local HaLow radio; set NODE to the node to measure from"
    NODE=$(node_name "$iface" "$BAT_HOSTS")
    [[ -n $NODE ]] || die "could not determine this node's name; set NODE"
  fi

  [[ -f $BAT_HOSTS ]] || die "roster not found: $BAT_HOSTS"

  if ! is_self "$NODE" "$BAT_HOSTS"; then
    local target
    target=$(node_target "$NODE" "$BAT_HOSTS" "$ULA_PREFIX")
    run_on_node true ||
      die "cannot reach $NODE at $target over ssh (see docs/MONITORING.md for laptop setup)"
  fi
}

# resolve_peer -- PEER as a roster name becomes a mesh address, so that nothing
# on the far end has to resolve it. A literal address or an off-roster name is
# passed through untouched.
PEER_ADDR=
resolve_peer() {
  [[ -n $PEER ]] || die "set PEER to the node to measure to"

  PEER_ADDR=$(node_mesh_addr "$PEER" "$BAT_HOSTS" "$ULA_PREFIX")
  if [[ -z $PEER_ADDR ]]; then
    PEER_ADDR=$PEER
    warn "$PEER is not in $BAT_HOSTS; using it as an address verbatim"
  fi

  if [[ -z $PEER_MAC ]]; then
    PEER_MAC=$(node_mac "$PEER" "$BAT_HOSTS")
  fi
}

# take_probe -- one sample from NODE, parsed into P.
#
# The raw text is kept so a run can be re-examined without repeating the walk,
# and because the parsers below make assumptions about batctl and iw output
# that vary by version. If a column mapping turns out wrong, nothing is lost.
RAW_SINK=
LAST_RAW=
take_probe() {
  LAST_RAW=$(probe_node "$NODE" "$BAT_HOSTS" "$ULA_PREFIX" \
    "$IFACE" "$MESHIF" "$PEER_ADDR" "$PING_TIMEOUT")

  if [[ -n $RAW_SINK ]]; then
    printf '%s\n' "$LAST_RAW" >>"$RAW_SINK"
  fi

  # Process substitution, not a pipe. `... | kv_load` runs kv_load in a subshell
  # (bash does this for every pipeline element without `shopt -s lastpipe`), so
  # P would be populated in a child that then exits and every reading would come
  # back empty -- silently, as blank CSV columns rather than an error.
  kv_load < <(
    printf '%s\n' "$LAST_RAW" | probe_section PROBE_TS |
      awk 'NF {print "probe_ts=" $1; exit}'
    printf '%s\n' "$LAST_RAW" | probe_section STATION | parse_station "$PEER_MAC"
    printf '%s\n' "$LAST_RAW" | probe_section SURVEY | parse_survey
    printf '%s\n' "$LAST_RAW" | probe_section ORIGINATORS |
      parse_originators "$(peer_orig_key)"
    printf '%s\n' "$LAST_RAW" | probe_section PING | parse_ping
    printf '%s\n' "$LAST_RAW" | probe_section CHRONY | parse_chrony
  )
}

# peer_orig_key -- how the peer appears in the originator table.
#
# batctl substitutes names from /etc/bat-hosts when it has them and prints raw
# hex when it does not, and the two cases are indistinguishable from here. Feed
# it the MAC, which is what an unsubstituted table holds; a table that IS
# substituted falls back to the best-route reading, which is correct whenever
# the fleet is a pair and approximately right otherwise.
peer_orig_key() { printf '%s' "$PEER_MAC"; }

rotate_if_big() {
  local f=$1 sz
  [[ -f $f ]] || return 0
  sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
  if ((sz > MAX_FILE_MB * 1024 * 1024)); then
    mv "$f" "${f}.$(date +%s).rot"
  fi
}

trap 'ssh_teardown' EXIT

# --------------------------------------------------------------------------
# The wide sample row
# --------------------------------------------------------------------------
#
# One column list, shared by `walk` and `soak`, so the two produce joinable
# files and a parser written for one reads the other.
#
# It is much wider than the old walk's eleven columns, deliberately. A walk is
# expensive -- somebody physically carries a node into a field -- and the
# fields that were missing are the ones that move first. Retries and failures
# climb well before pings start dropping; channel busy time separates "the link
# degraded" from "something else started transmitting", which look identical in
# RSSI; and noise gives an SNR, which is what actually predicts whether a rate
# can be held, in a way a bare RSSI does not.

SAMPLE_HEADER=$(
  printf '%s' \
    'ts,probe_ts,elapsed_s,node,peer,state,' \
    'rssi,rssi_avg,noise_dbm,snr_db,' \
    'tx_bitrate_mbps,tx_mcs,tx_nss,rx_bitrate_mbps,rx_mcs,expected_tput_mbps,' \
    'tx_packets,tx_retries,tx_failed,rx_packets,rx_drop_misc,' \
    'retry_rate,inactive_ms,connected_s,beacon_loss,beacon_signal_avg,' \
    'tq,nexthop,direct,originator_count,last_seen_s,' \
    'freq_mhz,survey_active_ms,survey_busy_ms,busy_pct,' \
    'ping_ok,rtt_ms,clock_last_offset_s,clock_rms_offset_s,clock_stratum,' \
    'bw_mhz,height_m'
)

# Cumulative counters from the previous sample, so a per-interval retry rate can
# be reported alongside them. The raw counters are monotonic since association,
# which makes them useless for spotting the moment a link turns marginal; the
# delta is the whole point.
PREV_TX_PACKETS=
PREV_TX_RETRIES=

# Set by sample_row, so the progress line can show it without reading back the
# CSV it just wrote.
LAST_RETRY_RATE=

sample_row() {
  local elapsed=$1 state=$2
  local snr='' retry_rate='' ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local rssi noise txpkt txretry
  rssi=$(p rssi)
  noise=$(p noise_dbm)
  txpkt=$(p tx_packets)
  txretry=$(p tx_retries)

  if [[ -n $rssi && -n $noise ]]; then
    snr=$(awk -v r="$rssi" -v n="$noise" 'BEGIN {printf "%.1f", r - n}')
  fi

  if [[ -n $txpkt && -n $txretry && -n $PREV_TX_PACKETS && -n $PREV_TX_RETRIES ]]; then
    retry_rate=$(awk -v p="$txpkt" -v pp="$PREV_TX_PACKETS" \
      -v r="$txretry" -v pr="$PREV_TX_RETRIES" '
      BEGIN {
        dp = p - pp; dr = r - pr
        # A counter that went backwards means the station re-associated; report
        # nothing rather than a negative rate.
        if (dp > 0 && dr >= 0) printf "%.4f", dr / dp
      }')
  fi
  PREV_TX_PACKETS=$txpkt
  PREV_TX_RETRIES=$txretry
  LAST_RETRY_RATE=$retry_rate

  printf '%s,%s,%s,%s,%s,%s,' \
    "$ts" "$(p probe_ts)" "$elapsed" "$NODE" "$PEER" "$state"
  printf '%s,%s,%s,%s,' \
    "$rssi" "$(p rssi_avg)" "$noise" "$snr"
  printf '%s,%s,%s,%s,%s,%s,' \
    "$(p tx_bitrate_mbps)" "$(p tx_mcs)" "$(p tx_nss)" \
    "$(p rx_bitrate_mbps)" "$(p rx_mcs)" "$(p expected_tput_mbps)"
  printf '%s,%s,%s,%s,%s,' \
    "$txpkt" "$txretry" "$(p tx_failed)" "$(p rx_packets)" "$(p rx_drop_misc)"
  printf '%s,%s,%s,%s,%s,' \
    "$retry_rate" "$(p inactive_ms)" "$(p connected_s)" \
    "$(p beacon_loss)" "$(p beacon_signal_avg)"
  printf '%s,%s,%s,%s,%s,' \
    "$(p tq)" "$(p nexthop)" "$(p direct)" "$(p originator_count)" "$(p last_seen_s)"
  printf '%s,%s,%s,%s,' \
    "$(p freq_mhz)" "$(p survey_active_ms)" "$(p survey_busy_ms)" "$(p busy_pct)"
  printf '%s,%s,%s,%s,%s,' \
    "$(p ping_ok)" "$(p rtt_ms)" \
    "$(p clock_last_offset_s)" "$(p clock_rms_offset_s)" "$(p clock_stratum)"
  printf '%s,%s\n' "$BW_MHZ" "$HEIGHT_M"
}

# --------------------------------------------------------------------------
# `hosts` -- the roster as /etc/hosts entries
# --------------------------------------------------------------------------
#
# For the two machines that never run install_network_stack.sh: the OpenWrt
# router, which has no systemd and so no installer to run, and the laptop.
# Paste the output into /etc/hosts on either.
mode_hosts() {
  [[ -f $BAT_HOSTS ]] || die "roster not found: $BAT_HOSTS"
  hosts_block "$BAT_HOSTS" "$ULA_PREFIX"
}

# --------------------------------------------------------------------------
# `status` -- one-shot fleet health
# --------------------------------------------------------------------------
#
# Absorbs `halow-batman.sh status` and the verify blocks from README.md and
# docs/OPENWRT.md. Unlike those, it runs against every node in the roster
# rather than only the machine it is typed on, which is the whole reason to
# drive the fleet from a laptop.
mode_status() {
  [[ -f $BAT_HOSTS ]] || die "roster not found: $BAT_HOSTS"

  local nodes
  if [[ -n $NODE ]]; then
    nodes=$NODE
  else
    nodes=$(fleet_nodes "$BAT_HOSTS")
  fi

  # Probed once and kept. A status run against four nodes is four ssh round
  # trips; re-probing for the detail dump would double that, and worse, the
  # summary line and the detail underneath it would then describe two different
  # instants.
  declare -A RAW
  local n addr
  for n in $nodes; do
    RAW[$n]=$(probe_node "$n" "$BAT_HOSTS" "$ULA_PREFIX" \
      "$IFACE" "$MESHIF" "" "$PING_TIMEOUT")
  done

  printf '\n  fleet: %s\n  prefix: %s::/64\n\n' \
    "$(echo "$nodes" | tr '\n' ' ')" "$ULA_PREFIX"

  printf '  %-14s %-26s %-7s %-6s %-6s %-5s %-6s %s\n' \
    NODE ADDRESS REACH RSSI TQ PEERS BUSY% CLOCK
  printf '  %s\n' "$(printf '%.0s-' {1..92})"

  for n in $nodes; do
    addr=$(node_mesh_addr "$n" "$BAT_HOSTS" "$ULA_PREFIX")

    if [[ -z $(printf '%s' "${RAW[$n]}" | tr -d '[:space:]') ]]; then
      printf '  %-14s %-26s %-7s %s\n' "$n" "${addr:-?}" "no" "unreachable"
      continue
    fi

    # Process substitution, not a pipe -- see take_probe.
    kv_load < <(
      printf '%s\n' "${RAW[$n]}" | probe_section STATION | parse_station ""
      printf '%s\n' "${RAW[$n]}" | probe_section SURVEY | parse_survey
      printf '%s\n' "${RAW[$n]}" | probe_section ORIGINATORS | parse_originators ""
      printf '%s\n' "${RAW[$n]}" | probe_section CHRONY | parse_chrony
    )

    printf '  %-14s %-26s %-7s %-6s %-6s %-5s %-6s %s\n' \
      "$n" "${addr:-?}" "yes" \
      "${P[rssi]:--}" "${P[tq]:--}" "${P[originator_count]:--}" \
      "${P[busy_pct]:--}" "${P[clock_last_offset_s]:--}"
  done

  printf '\n'

  # `iw dev halow0 link` is not enough on its own -- IBSS forms a cell of one
  # and looks healthy with no peer -- and batman-adv likewise forms a mesh of
  # one that forwards nothing, so the originator table is the real check.
  for n in $nodes; do
    [[ -n $(printf '%s' "${RAW[$n]}" | tr -d '[:space:]') ]] || continue

    printf '  ===== %s: originators =====\n' "$n"
    printf '%s\n' "${RAW[$n]}" | probe_section ORIGINATORS | sed 's/^/    /'
    printf '  ===== %s: IBSS peers =====\n' "$n"
    printf '%s\n' "${RAW[$n]}" | probe_section STATION |
      grep -E '^Station|signal:|tx bitrate|tx retries|tx failed' | sed 's/^/    /'
    printf '  ===== %s: gateways =====\n' "$n"
    printf '%s\n' "${RAW[$n]}" | probe_section GATEWAYS | sed 's/^/    /'
    printf '\n'
  done
}

# --------------------------------------------------------------------------
# `at` -- one measurement at a known distance
# --------------------------------------------------------------------------

mode_at() {
  local distance_m=${1:-} note=${2:-}

  [[ -n $distance_m ]] || usage
  [[ $distance_m =~ ^[0-9]+$ ]] || die "distance must be a whole number of metres"

  resolve_node
  resolve_peer
  mkdir -p "$LOGDIR"

  local out=${OUT:-$ROOT/rangetest.csv}
  local stamp base
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  base="$LOGDIR/${stamp}_${NODE}_${distance_m}m"

  RAW_SINK="$base.probes"

  # Radio state, verbatim. Recall the driver reports S1G channels as their
  # 5 GHz equivalents, so this is a 5GHz-looking channel/width -- BW_MHZ carries
  # the real sub-1GHz figure, which is why it is an input rather than a reading.
  run_on_node "iw dev $IFACE info" >"$base.iw-info" 2>&1
  local chan width
  chan=$(awk '/^\tchannel /{print $2; exit}' "$base.iw-info" 2>/dev/null)
  width=$(awk -F'width: ' '/width:/{split($2,a,","); print a[1]; exit}' \
    "$base.iw-info" 2>/dev/null)

  log "sampling from $NODE for $((SAMPLES * SAMPLE_INTERVAL))s..."
  local i
  : >"$base.rssi"
  : >"$base.samples"
  echo "$SAMPLE_HEADER" >>"$base.samples"
  for ((i = 0; i < SAMPLES; i++)); do
    take_probe
    [[ -n $(p rssi) ]] && printf '%s\n' "$(p rssi)" >>"$base.rssi"
    sample_row "$((i * SAMPLE_INTERVAL))" "sample" >>"$base.samples"
    sleep "$SAMPLE_INTERVAL"
  done

  local n avg min max
  read -r n avg min max <<<"$(awk '
    NR==1 {min=$1; max=$1}
    {sum+=$1; if ($1<min) min=$1; if ($1>max) max=$1; n++}
    END {if (n) printf "%d %.1f %d %d", n, sum/n, min, max; else print "0 0 0 0"}
  ' "$base.rssi")"

  # No samples means no peer in the station dump for the whole window. Record
  # the row with empty RSSI rather than dying: the ping below still
  # distinguishes "out of range" from "never associated", and a blank cell at a
  # known distance is data -- often the data the trip was made for.
  if [[ $n -eq 0 ]]; then
    warn "no RSSI samples captured -- link is down at this position"
    avg='' min='' max=''
  else
    # The lesson from bench testing: a very strong signal saturates the receiver
    # and looks like a driver fault. Unlikely outdoors, but flag it rather than
    # let it silently poison a data set.
    awk -v a="$avg" 'BEGIN {exit !(a > -25)}' &&
      warn "mean RSSI ${avg} dBm is implausibly strong; check attenuation"
  fi

  # The sustained ping runs on the node, over the mesh interface, for the same
  # reason every other reading does.
  log "pinging $PEER from $NODE ($PING_COUNT packets)..."
  run_on_node "pingif=$MESHIF; ip link show $MESHIF >/dev/null 2>&1 || pingif=$IFACE;
    ping -I \"\$pingif\" -c $PING_COUNT -i $PING_INTERVAL -q $PEER_ADDR" \
    >"$base.ping" 2>&1

  local loss rtt
  loss=$(awk -F'[ %]' '/packet loss/{for(i=1;i<=NF;i++) if($i=="packet") print $(i-2)}' \
    "$base.ping" | head -1)
  rtt=$(awk -F'/' '/^(rtt|round-trip)/{print $5; exit}' "$base.ping")
  loss=${loss:-100}
  rtt=${rtt:-}

  local tput=
  if [[ $IPERF == 1 ]]; then
    # Bind to the mesh address. Unbound, iperf3 picks a source by routing table
    # and can leave over Ethernet -- reporting a link that was never measured.
    # This is also why a client on the node that cannot reach the server fails
    # while the reverse direction works: run the server on whichever end you
    # can already ping.
    local bindaddr
    bindaddr=$(node_mesh_addr "$NODE" "$BAT_HOSTS" "$ULA_PREFIX")

    log "iperf3 $NODE -> $PEER for ${IPERF_TIME}s..."
    if run_on_node "iperf3 -c $PEER_ADDR ${bindaddr:+-B $bindaddr} -t $IPERF_TIME -J" \
      >"$base.iperf.json" 2>&1; then
      tput=$(awk -F'[:,]' '/"bits_per_second"/{v=$2} END {if (v) printf "%.3f", v/1e6}' \
        "$base.iperf.json" 2>/dev/null)
    else
      # Silence here is what made this look like a driver problem in the field.
      warn "iperf3 failed -- is 'iperf3 -s' running on $PEER? see $base.iperf.json"
    fi
  fi

  run_on_node "morse_cli -i $IFACE stats" >"$base.morse-stats" 2>&1

  if [[ ! -f $out ]]; then
    echo "timestamp,node,peer,distance_m,bw_mhz,height_m,rssi_avg,rssi_min,rssi_max,samples,noise_dbm,snr_db,busy_pct,retry_rate,loss_pct,rtt_ms,batman_tq,direct,mbps,channel,width,note" \
      >"$out"
  fi

  local snr=
  if [[ -n $avg && -n $(p noise_dbm) ]]; then
    snr=$(awk -v r="$avg" -v n="$(p noise_dbm)" 'BEGIN {printf "%.1f", r - n}')
  fi

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,"%s"\n' \
    "$stamp" "$NODE" "$PEER" "$distance_m" "$BW_MHZ" "$HEIGHT_M" \
    "$avg" "$min" "$max" "$n" \
    "$(p noise_dbm)" "$snr" "$(p busy_pct)" "$(p retry_rate)" \
    "$loss" "$rtt" "$(p tq)" "$(p direct)" "$tput" \
    "$chan" "$width" "$note" >>"$out"

  cat <<-EOF

	  $NODE -> $PEER
	  distance     ${distance_m} m    bandwidth ${BW_MHZ:-?} MHz    height ${HEIGHT_M:-?} m
	  RSSI         ${avg:-n/a} dBm  (min ${min:-n/a}, max ${max:-n/a}, n=${n})
	  noise / SNR  ${P[noise_dbm]:-n/a} dBm / ${snr:-n/a} dB
	  channel busy ${P[busy_pct]:-n/a} %
	  packet loss  ${loss}%
	  rtt avg      ${rtt:-n/a} ms
	  batman TQ    ${P[tq]:-n/a} / 255  (direct hop: ${P[direct]:-n/a})
	  throughput   ${tput:-n/a} Mbps
	  logs         ${base}.*
	  appended to  ${out}

	EOF

  # Deployment wants margin, not a link that merely passed once.
  if [[ ${loss%.*} -gt 0 ]]; then
    log "NOTE: non-zero loss at this position -- not a usable hop"
  fi
}

# --------------------------------------------------------------------------
# `tp` -- a throughput measurement at a surveyed distance, run by hand
# --------------------------------------------------------------------------
#
# Deliberately separate from `at` rather than a flag on it. `at` is a passive
# reading: it observes a link without changing it, and can be repeated freely.
# A throughput run saturates the channel -- at 1 MHz there are only a few
# hundred kbit/s to saturate -- so it is not an observation of the deployment,
# it is a load test, and every passive number taken during one describes a
# link under load rather than the link you are deploying.
#
# Keeping them apart in the tool is what keeps them apart in the CSV, which is
# what stops the two being averaged together six months from now.
#
#   NODE=olo PEER=wazza BW_MHZ=1 HEIGHT_M=4 ./batman_oracle.sh tp 750 "clear LOS"
#
# A probe is taken immediately before the run, so the row carries the RSSI, TQ
# and channel-busy figures that held going in. A throughput number without them
# cannot be compared against a number taken on a different day.

# tp_run <direction> <peer_addr> <bind_addr> <json_out> -- one direction.
# Returns the Mbit/s figure on stdout, empty on failure.
tp_run() {
  local dir=$1 paddr=$2 bindaddr=$3 jsonout=$4
  local rflag=""
  [[ $dir == reverse ]] && rflag="-R"

  if [[ $TP_AUTOSERVER == 1 ]]; then
    # -1 exits after one client, -D backgrounds it. Nothing to tear down, and
    # no listener left behind on a node that may be walked out of reach.
    node_run "$PEER" "$BAT_HOSTS" "$ULA_PREFIX" \
      "iperf3 -s -1 -D >/dev/null 2>&1 || true" >/dev/null 2>&1
    sleep 1
  fi

  if run_on_node \
    "iperf3 -c $paddr ${bindaddr:+-B $bindaddr} -t $TP_TIME -O $TP_OMIT $rflag -J" \
    >"$jsonout" 2>&1; then
    # sum_received is the figure that survived the network; sum_sent includes
    # anything the sender queued and lost. On a link this narrow the two can
    # differ by a lot, and the received figure is the honest one.
    awk -F'[:,]' '
      /"sum_received"/ { inrecv = 1 }
      inrecv && /"bits_per_second"/ { v = $2; exit }
      { if (/"bits_per_second"/) last = $2 }
      END { if (v == "") v = last; if (v != "") printf "%.3f", v / 1e6 }
    ' "$jsonout" 2>/dev/null
  fi
}

mode_tp() {
  local distance_m=${1:-} note=${2:-}

  [[ -n $distance_m ]] || usage
  [[ $distance_m =~ ^[0-9]+$ ]] || die "distance must be a whole number of metres"

  resolve_node
  resolve_peer
  mkdir -p "$LOGDIR"

  local stamp base
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  base="$LOGDIR/${stamp}_${NODE}-to-${PEER}_${distance_m}m_tp"
  RAW_SINK="$base.probes"

  # Link state going in. Without it the throughput figure is uninterpretable:
  # a low number at -95 dBm is physics, the same number at -60 dBm is a fault.
  take_probe
  local snr=
  [[ -n $(p rssi) && -n $(p noise_dbm) ]] &&
    snr=$(awk -v r="$(p rssi)" -v n="$(p noise_dbm)" 'BEGIN {printf "%.1f", r - n}')

  if [[ $(p ping_ok) != 1 ]]; then
    warn "$PEER is not answering pings from $NODE -- iperf3 will almost certainly fail"
  fi

  local bindaddr fwd='' rev=''
  bindaddr=$(node_mesh_addr "$NODE" "$BAT_HOSTS" "$ULA_PREFIX")

  log "throughput $NODE -> $PEER, ${TP_TIME}s (+${TP_OMIT}s discarded)..."
  fwd=$(tp_run forward "$PEER_ADDR" "$bindaddr" "$base.forward.json")
  [[ -n $fwd ]] ||
    warn "forward direction failed; see $base.forward.json"

  if [[ $TP_REVERSE == 1 ]]; then
    log "throughput $PEER -> $NODE, ${TP_TIME}s..."
    rev=$(tp_run reverse "$PEER_ADDR" "$bindaddr" "$base.reverse.json")
    [[ -n $rev ]] ||
      warn "reverse direction failed; see $base.reverse.json"
  fi

  # A second probe, so retry counters can be differenced across the run. This
  # is the clearest signal of a link that is nominally up but working hard:
  # throughput holds while the retry rate climbs, right up until it does not.
  local retry_during
  take_probe
  retry_during=$LAST_RETRY_RATE

  local out=${TP_OUT:-$ROOT/throughput.csv}
  if [[ ! -f $out ]]; then
    echo "timestamp,node,peer,distance_m,bw_mhz,height_m,fwd_mbps,rev_mbps,rssi,noise_dbm,snr_db,busy_pct,tq,direct,retry_rate,rtt_ms,tp_time_s,note" \
      >"$out"
  fi

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,"%s"\n' \
    "$stamp" "$NODE" "$PEER" "$distance_m" "$BW_MHZ" "$HEIGHT_M" \
    "$fwd" "$rev" \
    "$(p rssi)" "$(p noise_dbm)" "$snr" "$(p busy_pct)" \
    "$(p tq)" "$(p direct)" "$retry_during" "$(p rtt_ms)" \
    "$TP_TIME" "$note" >>"$out"

  local rev_shown=$rev
  if [[ $TP_REVERSE != 1 ]]; then
    rev_shown="skipped"
  elif [[ -z $rev ]]; then
    rev_shown="FAILED"
  fi

  cat <<-EOF

	  $NODE <-> $PEER at ${distance_m} m
	  bandwidth    ${BW_MHZ:-?} MHz    height ${HEIGHT_M:-?} m
	  forward      ${fwd:-FAILED} Mbps   ($NODE -> $PEER)
	  reverse      ${rev_shown} Mbps   ($PEER -> $NODE)
	  RSSI / SNR   $(p rssi) dBm / ${snr:-n/a} dB
	  channel busy $(p busy_pct) %
	  batman TQ    $(p tq) / 255
	  retry rate   ${retry_during:-n/a}
	  logs         ${base}.*
	  appended to  ${out}

	EOF
}

# --------------------------------------------------------------------------
# `walk` -- continuous trace while a node moves
# --------------------------------------------------------------------------
#
# Run with NODE set to the STATIONARY node. Nothing here knows how far away the
# walker is: correlate elapsed_s against a GPS track, or against a paper
# notebook, afterwards. There is deliberately no in-band annotation -- typing
# into the terminal that is driving the sampler is a good way to lose a sample
# and a bad way to keep a log.

WALK_OUT=
START_EPOCH=0
STATE=up
CONSEC_FAIL=0
LOSS_STARTED_AT=

LAST_GOOD_ELAPSED=
LAST_GOOD_RSSI=
LAST_GOOD_SNR=

# Worst RSSI still carrying traffic -- the practical sensitivity floor for this
# bandwidth, and the number the whole range budget rests on.
MIN_GOOD_RSSI=
MIN_GOOD_SNR=
MAX_BUSY=

EVENTS=()

walk_summary() {
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  printf '\n' >&2
  cat >&2 <<-EOF
	  ---- walk summary ----
	  $NODE -> $PEER
	  bandwidth        ${BW_MHZ:-?} MHz    antenna height ${HEIGHT_M:-?} m
	  duration         $(($(date +%s) - START_EPOCH))s
	  final state      $STATE
	  last good at     ${LAST_GOOD_ELAPSED:-n/a}s elapsed, RSSI ${LAST_GOOD_RSSI:-n/a} dBm (SNR ${LAST_GOOD_SNR:-n/a} dB)
	  weakest working  ${MIN_GOOD_RSSI:-n/a} dBm  (SNR ${MIN_GOOD_SNR:-n/a} dB)
	  peak channel bus ${MAX_BUSY:-n/a} %
	  csv              $WALK_OUT
	  raw probes       ${RAW_SINK:-none}
	EOF

  if [[ ${#EVENTS[@]} -gt 0 ]]; then
    printf '  events\n' >&2
    printf '    %s\n' "${EVENTS[@]}" >&2
  fi

  printf '\n  Weakest working RSSI is the practical sensitivity floor at this\n' >&2
  printf '  bandwidth. Budget 15-20 dB above it for a link you intend to rely on.\n' >&2
  printf '  If peak channel busy is high, suspect contention before path loss.\n\n' >&2

  printf '# %s end state=%s last_good_elapsed=%s last_good_rssi=%s min_good_rssi=%s min_good_snr=%s max_busy_pct=%s\n' \
    "$now" "$STATE" "${LAST_GOOD_ELAPSED:-}" "${LAST_GOOD_RSSI:-}" \
    "${MIN_GOOD_RSSI:-}" "${MIN_GOOD_SNR:-}" "${MAX_BUSY:-}" >>"$WALK_OUT"
}

mode_walk() {
  resolve_node
  resolve_peer
  mkdir -p "$LOGDIR"

  WALK_OUT=${OUT:-$ROOT/walktest.csv}
  RAW_SINK="$LOGDIR/$(date -u +%Y%m%dT%H%M%SZ)_${NODE}_walk.probes"

  [[ -f $WALK_OUT ]] || echo "$SAMPLE_HEADER" >"$WALK_OUT"

  START_EPOCH=$(date +%s)
  trap 'walk_summary; ssh_teardown; exit 0' INT TERM

  log "walking $NODE -> $PEER ($PEER_ADDR), sampling every ${SAMPLE_INTERVAL}s"
  log "Ctrl-C to finish; annotate distances in your notebook against elapsed_s"

  while :; do
    local elapsed rssi snr busy
    elapsed=$(($(date +%s) - START_EPOCH))

    take_probe

    rssi=$(p rssi)
    busy=$(p busy_pct)
    snr=
    [[ -n $rssi && -n $(p noise_dbm) ]] &&
      snr=$(awk -v r="$rssi" -v n="$(p noise_dbm)" 'BEGIN {printf "%.1f", r - n}')

    # Ping is the authority on whether the link carries traffic: a station can
    # linger in `iw station dump` well after it stops being reachable.
    if [[ $(p ping_ok) == 1 ]]; then
      CONSEC_FAIL=0
      if [[ -n $rssi ]]; then
        LAST_GOOD_ELAPSED=$elapsed
        LAST_GOOD_RSSI=$rssi
        LAST_GOOD_SNR=$snr
        if [[ -z $MIN_GOOD_RSSI ]] || ((rssi < MIN_GOOD_RSSI)); then
          MIN_GOOD_RSSI=$rssi
          MIN_GOOD_SNR=$snr
        fi
      fi

      if [[ $STATE == down ]]; then
        STATE=up
        EVENTS+=("${elapsed}s REGAINED (rssi ${rssi:-?} dBm)")
        log "link REGAINED at ${elapsed}s, RSSI ${rssi:-?} dBm"
      fi
    else
      CONSEC_FAIL=$((CONSEC_FAIL + 1))
      if [[ $STATE == up && $CONSEC_FAIL -ge $LOSS_HOLD ]]; then
        STATE=down
        LOSS_STARTED_AT=$elapsed
        EVENTS+=("${elapsed}s LOST (last good ${LAST_GOOD_ELAPSED:-?}s @ ${LAST_GOOD_RSSI:-?} dBm)")
        log "link LOST at ${elapsed}s; last good ${LAST_GOOD_RSSI:-?} dBm at ${LAST_GOOD_ELAPSED:-?}s"
      fi
    fi

    if [[ -n $busy ]]; then
      if [[ -z $MAX_BUSY ]] || awk -v a="$busy" -v b="$MAX_BUSY" 'BEGIN{exit !(a>b)}'; then
        MAX_BUSY=$busy
      fi
    fi

    sample_row "$elapsed" "$STATE" >>"$WALK_OUT"

    printf '\r  %5ss %-4s rssi %-5s snr %-5s rate %-5s tq %-4s retry %-7s busy %-5s rtt %-6s ping %s  ' \
      "$elapsed" "$STATE" "${rssi:-n/a}" "${snr:-n/a}" \
      "$(p tx_bitrate_mbps)" "$(p tq)" "${LAST_RETRY_RATE:-n/a}" \
      "${busy:-n/a}" "$(p rtt_ms)" "$(p ping_ok)" >&2

    if [[ $STATE == down && $EXIT_AFTER_LOSS -gt 0 && -n $LOSS_STARTED_AT ]]; then
      if ((elapsed - LOSS_STARTED_AT >= EXIT_AFTER_LOSS)); then
        log "down for ${EXIT_AFTER_LOSS}s; stopping"
        walk_summary
        exit 0
      fi
    fi

    sleep "$SAMPLE_INTERVAL"
  done
}

# --------------------------------------------------------------------------
# `soak` -- unattended logging for offline analysis
# --------------------------------------------------------------------------
#
# The passive/active split matters here more than anywhere else. TQ, RSSI,
# retries and channel busy are observations: cheap, and safe to leave running
# for a whole deployment. A throughput burst is not an observation, it is a
# load test that saturates the link and makes every passive number taken during
# it a measurement of a saturated link. They are kept apart in the files for
# the same reason they must be kept apart in the analysis.

soak_wait_for_sync() {
  local n=$1

  if ! node_run "$n" "$BAT_HOSTS" "$ULA_PREFIX" "command -v chronyc" >/dev/null 2>&1; then
    warn "$n: chronyc not found -- cannot verify clock sync"
    [[ $REQUIRE_SYNC == 1 ]] && die "REQUIRE_SYNC=1, aborting"
    return 0
  fi

  log "$n: waiting up to ${SYNC_TIMEOUT}s for clock sync (offset < ${SYNC_MAX_OFFSET}s)..."
  # `chronyc waitsync <max-tries> <max-correction>`: 0 tries is unlimited, so
  # the remote `timeout` enforces the budget instead.
  if node_run "$n" "$BAT_HOSTS" "$ULA_PREFIX" \
    "timeout $SYNC_TIMEOUT chronyc waitsync 0 $SYNC_MAX_OFFSET 0.0 1" >/dev/null 2>&1; then
    log "$n: clock synced"
    return 0
  fi

  warn "$n: clock NOT synced within ${SYNC_TIMEOUT}s"
  node_run "$n" "$BAT_HOSTS" "$ULA_PREFIX" "chronyc tracking" 2>&1 | sed 's/^/    /' >&2
  if [[ $REQUIRE_SYNC == 1 ]]; then
    die "REQUIRE_SYNC=1, aborting so you do not log unjoinable timestamps"
  fi
  warn "$n: continuing anyway; timestamps may not align across nodes"
}

mode_soak() {
  resolve_node

  local peers
  if [[ -n $SOAK_PEERS ]]; then
    peers=$SOAK_PEERS
  else
    peers=$(fleet_nodes "$BAT_HOSTS" | grep -vx "$NODE" | tr '\n' ' ')
  fi
  [[ -n ${peers// /} ]] || die "no peers to probe (roster has only $NODE?)"

  local out="$LOGDIR/soak_${NODE}"
  mkdir -p "$out"

  soak_wait_for_sync "$NODE"

  local samples="$out/samples_${NODE}.csv"
  local origs="$out/originators_${NODE}.csv"
  local stats="$out/batstats_${NODE}.csv"
  local tplog="$out/throughput_${NODE}.log"
  local meta="$out/meta_${NODE}.txt"
  RAW_SINK="$out/probes_${NODE}.log"

  [[ -s $samples ]] || echo "$SAMPLE_HEADER" >"$samples"
  [[ -s $origs ]] || echo "ts,node,originator,tq,nexthop,last_seen_s,best" >"$origs"
  [[ -s $stats ]] || echo "ts,node,metric,value" >"$stats"

  # One-shot environment snapshot, so offline you know exactly what ran.
  {
    echo "node=$NODE"
    echo "peers=$peers"
    echo "captured_at_epoch=$(date +%s.%N)"
    echo "captured_at_iso=$(date -Is)"
    echo "oracle_host=$(hostname)"
    echo "iface=$IFACE meshif=$MESHIF"
    echo "ula_prefix=$ULA_PREFIX"
    # Not readable from the driver: S1G channels are reported as their 5 GHz
    # equivalents, so these are inputs and belong in the record.
    echo "bw_mhz=${BW_MHZ:-unset} height_m=${HEIGHT_M:-unset}"
    echo "--- versions ---"
    run_on_node "batctl -v; iw --version; morse_cli -i $IFACE version" 2>&1
    echo "--- chrony ---"
    run_on_node "chronyc tracking; chronyc sources" 2>&1
  } >"$meta"

  log "soaking from $NODE against: $peers"
  log "output: $out -- Ctrl-C to stop"

  trap 'log "stopped; logs in $out"; ssh_teardown; exit 0' INT TERM

  SOAK_START=$(date +%s)
  local last_tp=0
  while :; do
    local peer_name
    for peer_name in $peers; do
      PEER=$peer_name
      PEER_MAC=
      resolve_peer

      take_probe
      sample_row "$(($(date +%s) - SOAK_START))" "soak" >>"$samples"

      # Per-originator rows, not just the best route. With four nodes the
      # interesting question is which paths exist and when they flip, and a
      # single best-TQ figure cannot answer it.
      local ts
      ts=$(p probe_ts)
      printf '%s\n' "$LAST_RAW" | probe_section ORIGINATORS |
        awk -v t="$ts" -v n="$NODE" '
          /^[[:space:]]*(Originator|\[|B\.A\.T\.M\.A\.N\.)/ {next}
          {
            line = $0
            best = (line ~ /^[[:space:]]*\*/) ? 1 : 0
            sub(/^[[:space:]]*\*?[[:space:]]*/, "", line)
            if (!match(line, /\([ ]*[0-9]+\)/)) next
            tq = substr(line, RSTART + 1, RLENGTH - 2); gsub(/ /, "", tq)
            nf = split(line, f, /[[:space:]]+/)
            nh = ""
            for (i = 3; i <= nf; i++) if (f[i] ~ /\)$/) { nh = f[i+1]; break }
            print t "," n "," f[1] "," tq "," nh "," f[2] "," best
          }' >>"$origs"
    done

    # batman counters, long format -- one metric per row, so a new counter in a
    # future batctl adds rows rather than breaking a column mapping.
    run_on_node "batctl meshif $MESHIF statistics" 2>/dev/null |
      awk -v t="$(date +%s.%N)" -v n="$NODE" '
        { k = $1; v = $NF; gsub(/:/, "", k)
          if (k != "" && v ~ /^[0-9]+$/) print t "," n "," k "," v }' >>"$stats"

    if [[ $SOAK_THROUGHPUT == 1 ]] && (($(date +%s) - last_tp >= TP_INTERVAL)); then
      last_tp=$(date +%s)
      local bindaddr
      bindaddr=$(node_mesh_addr "$NODE" "$BAT_HOSTS" "$ULA_PREFIX")
      # One pair at a time. In a shared medium concurrent flows contend for
      # airtime and corrupt each other's numbers -- and with every node running
      # its own soak, the bursts must be staggered fleet-wide too, which this
      # cannot do on its own. Run throughput from ONE node only.
      for peer_name in $peers; do
        local paddr
        paddr=$(node_mesh_addr "$peer_name" "$BAT_HOSTS" "$ULA_PREFIX")
        echo "### BEGIN peer=$peer_name start=$(date +%s.%N) dur=${TP_DURATION}s" >>"$tplog"
        run_on_node "iperf3 -c $paddr ${bindaddr:+-B $bindaddr} -t $TP_DURATION -J" \
          >>"$tplog" 2>&1 || echo "  (iperf3 to $peer_name failed)" >>"$tplog"
        echo "### END peer=$peer_name end=$(date +%s.%N)" >>"$tplog"
      done
    fi

    rotate_if_big "$samples"
    rotate_if_big "$origs"
    rotate_if_big "$stats"
    rotate_if_big "$tplog"
    rotate_if_big "$RAW_SINK"

    sleep "$SAMPLE_INTERVAL"
  done
}

# --------------------------------------------------------------------------

case "${1:-}" in
status)
  shift
  mode_status "$@"
  ;;
at)
  shift
  mode_at "$@"
  ;;
tp)
  shift
  mode_tp "$@"
  ;;
walk)
  shift
  mode_walk "$@"
  ;;
soak)
  shift
  mode_soak "$@"
  ;;
hosts)
  shift
  mode_hosts "$@"
  ;;
*) usage ;;
esac
