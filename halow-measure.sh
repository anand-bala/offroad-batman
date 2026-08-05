#!/usr/bin/env bash
#
# halow-measure.sh -- field link-quality measurement, in two modes.
#
#   at <distance_m> [note]   one careful measurement at a surveyed distance
#   walk                     continuous trace while a node walks away
#
# These were halow-rangetest.sh and halow-walktest.sh. They are one tool with
# two sampling strategies -- same radio reads, same CSV discipline, same raw
# logs -- and keeping them apart meant the RSSI sampler and the ping-interface
# selection existed in two copies that had to be fixed twice.
#
# Use `at` for a number you intend to put in a range budget, and `walk` for
# finding the cliff edge. `at` trades coverage for precision; `walk` trades
# precision for a continuous trace of where the link actually dies.
#
#   sudo PEER=192.168.60.2 ./halow-measure.sh at 750
#   sudo PEER=wazza.lan BW_MHZ=1 HEIGHT_M=4 ./halow-measure.sh at 750 "clear LOS, dry"
#   sudo PEER=wazza.lan BW_MHZ=1 HEIGHT_M=4 OUT=walk-1mhz.csv ./halow-measure.sh walk
#
# Bandwidth changes need BOTH ends reconfigured, so a sweep means walking back.
# Plan positions around that: do every bandwidth at one distance before moving.
#
# Results append to CSV; raw tool output goes to rangetest-logs/ so a run can be
# re-examined without repeating the walk.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=halow-lib.sh
source "$ROOT/halow-lib.sh"
LOG_TAG=halow-measure

# --------------------------------------------------------------------------
# Configuration -- shared by both modes
# --------------------------------------------------------------------------

# Auto-detected by driver, so it works before and after the 10-halow.link
# rename. Set IFACE explicitly to override.
IFACE=${IFACE:-$(default_iface)}
MESHIF=${MESHIF:-bat0}

# Peer to ping. Hostname works if /etc/hosts is populated.
PEER=${PEER:-}

# Restrict RSSI sampling to one peer. Empty means "first station listed",
# which is what you want with exactly two nodes up.
PEER_MAC=${PEER_MAC:-}

# Seconds between radio reads. In `at` mode this paces the sampling window; in
# `walk` mode it is the loop period.
SAMPLE_INTERVAL=${SAMPLE_INTERVAL:-1}

# Recorded verbatim, not measured. Antenna height dominates path loss, so a
# row without it cannot be compared against any other row.
BW_MHZ=${BW_MHZ:-}
HEIGHT_M=${HEIGHT_M:-}

LOGDIR=${LOGDIR:-$ROOT/rangetest-logs}

# --------------------------------------------------------------------------
# Configuration -- `at` mode
# --------------------------------------------------------------------------

# RSSI fluctuates several dB outdoors -- a single reading is noise, not a
# measurement. Sample across a window and keep the spread.
SAMPLES=${SAMPLES:-30}

PING_COUNT=${PING_COUNT:-100}
PING_INTERVAL=${PING_INTERVAL:-0.2}

# Throughput needs `iperf3 -s` running on the peer. Off by default: it costs
# airtime and a battery, and RSSI plus loss already answers "does this work".
IPERF=${IPERF:-0}
IPERF_TIME=${IPERF_TIME:-10}

# --------------------------------------------------------------------------
# Configuration -- `walk` mode
# --------------------------------------------------------------------------

# Consecutive failed probes before calling the link down. One dropped ping at
# range is normal; several in a row is a cutoff. Raising this makes the script
# slower to declare loss but less prone to calling it early on a deep fade.
LOSS_HOLD=${LOSS_HOLD:-5}

# Stop after this many seconds of continuous loss. 0 runs until Ctrl-C, which
# is what you want if you expect the walker to come back into range.
EXIT_AFTER_LOSS=${EXIT_AFTER_LOSS:-0}

# Per-probe ping timeout, seconds. Keep it under SAMPLE_INTERVAL.
PING_TIMEOUT=${PING_TIMEOUT:-1}

# --------------------------------------------------------------------------

usage() {
  cat >&2 <<-EOF
	usage: PEER=<ip|host> $0 at <distance_m> [note]
	       PEER=<ip|host> $0 walk
	EOF
  exit 2
}

# Shared preflight. `at` adds a check that the link is up at all, because a
# one-shot measurement with no peer is just a wasted trip to the position.
preflight() {
  require_root "ping interval, iw access"
  [[ -n $PEER ]] || die "set PEER to the peer's IP or hostname"
  require_cmd iw
  require_iface "$IFACE"
  mkdir -p "$LOGDIR"
}

# --------------------------------------------------------------------------
# `at` -- one measurement at a known distance
# --------------------------------------------------------------------------

mode_at() {
  local distance_m=${1:-} note=${2:-}

  [[ -n $distance_m ]] || usage
  [[ $distance_m =~ ^[0-9]+$ ]] || die "distance must be a whole number of metres"

  preflight

  # A warning, not a failure. "No peer at this position" is itself a result --
  # often the one you walked out to find -- and dying here would discard the
  # RSSI and loss figures that establish where the edge is.
  iw dev "$IFACE" station dump 2>/dev/null | grep -q '^Station' ||
    log "warning: no peers on $IFACE -- recording the position anyway"

  local out=${OUT:-$ROOT/rangetest.csv}
  local stamp base
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  base="$LOGDIR/${stamp}_${distance_m}m"

  # Radio state, verbatim. Recall the driver reports S1G channels as their 5GHz
  # equivalents, so this is a 5GHz-looking channel/width -- BW_MHZ carries the
  # real sub-1GHz figure, which is why it is an input rather than a reading.
  iw dev "$IFACE" info >"$base.iw-info" 2>&1 || true
  local chan width
  chan=$(awk '/^\tchannel /{print $2; exit}' "$base.iw-info" 2>/dev/null || true)
  width=$(awk -F'width: ' '/width:/{split($2,a,","); print a[1]; exit}' \
    "$base.iw-info" 2>/dev/null || true)

  log "sampling RSSI for $((SAMPLES * SAMPLE_INTERVAL))s..."
  local i v
  for ((i = 0; i < SAMPLES; i++)); do
    v=$(sample_rssi "$IFACE" "$PEER_MAC")
    [[ -n $v ]] && printf '%s\n' "$v"
    sleep "$SAMPLE_INTERVAL"
  done >"$base.rssi"

  local n avg min max
  read -r n avg min max <<<"$(awk '
    NR==1 {min=$1; max=$1}
    {sum+=$1; if ($1<min) min=$1; if ($1>max) max=$1; n++}
    END {if (n) printf "%d %.1f %d %d", n, sum/n, min, max; else print "0 0 0 0"}
  ' "$base.rssi")"

  # No samples means no peer in station dump for the whole window. Record the
  # row with empty RSSI rather than dying: the ping result below still
  # distinguishes "out of range" from "never associated", and a blank cell at a
  # known distance is data.
  if [[ $n -eq 0 ]]; then
    log "warning: no RSSI samples captured -- link is down at this position"
    avg= min= max=
  else
    # The lesson from bench testing: a very strong signal saturates the receiver
    # and looks like a driver fault. Unlikely outdoors, but flag it rather than
    # let it silently poison a data set.
    awk -v a="$avg" 'BEGIN {exit !(a > -25)}' &&
      log "WARNING: mean RSSI ${avg} dBm is implausibly strong; check attenuation"
  fi

  log "pinging $PEER ($PING_COUNT packets)..."
  local pingif
  pingif=$(ping_iface "$IFACE" "$MESHIF")

  ping -I "$pingif" -c "$PING_COUNT" -i "$PING_INTERVAL" -q "$PEER" \
    >"$base.ping" 2>&1 || true

  local loss rtt
  loss=$(awk -F'[ %]' '/packet loss/{for(i=1;i<=NF;i++) if($i=="packet") print $(i-2)}' \
    "$base.ping" | head -1)
  rtt=$(awk -F'/' '/^(rtt|round-trip)/{print $5; exit}' "$base.ping")
  loss=${loss:-100}
  rtt=${rtt:-}

  # batman link quality, 0-255. Only meaningful once bat0 is up.
  local tq=
  if command -v batctl >/dev/null && ip link show "$MESHIF" >/dev/null 2>&1; then
    batctl meshif "$MESHIF" originators >"$base.originators" 2>&1 || true
    tq=$(tq_best <"$base.originators" 2>/dev/null || true)
  fi

  local tput=
  if [[ $IPERF == 1 ]]; then
    # Bind to the same address the ping used. Unbound, iperf3 picks a source by
    # routing table and can leave over Ethernet -- reporting a link that was
    # never measured. This is also why a client on the node that cannot reach
    # the server fails while the reverse direction works: run the server on
    # whichever end you can already ping.
    local bindaddr bind=()
    bindaddr=$(ip -4 -brief addr show dev "$pingif" 2>/dev/null |
      awk '{split($3, a, "/"); print a[1]; exit}')
    if [[ -n $bindaddr ]]; then
      bind=(-B "$bindaddr")
    else
      log "warning: no address on $pingif; iperf3 will pick its own source"
    fi

    log "iperf3 to $PEER for ${IPERF_TIME}s${bindaddr:+ from $bindaddr}..."
    if iperf3 -c "$PEER" "${bind[@]}" -t "$IPERF_TIME" -J \
      >"$base.iperf.json" 2>&1; then
      tput=$(awk -F'[:,]' '/"bits_per_second"/{v=$2} END {if (v) printf "%.3f", v/1e6}' \
        "$base.iperf.json" 2>/dev/null || true)
    else
      # Silence here is what made this look like a driver problem in the field.
      log "warning: iperf3 failed -- is 'iperf3 -s' running on $PEER? see $base.iperf.json"
    fi
  fi

  morse_cli -i "$IFACE" stats >"$base.morse-stats" 2>&1 || true

  if [[ ! -f $out ]]; then
    echo "timestamp,distance_m,bw_mhz,height_m,rssi_avg,rssi_min,rssi_max,samples,loss_pct,rtt_ms,batman_tq,mbps,channel,width,note" \
      >"$out"
  fi

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,"%s"\n' \
    "$stamp" "$distance_m" "$BW_MHZ" "$HEIGHT_M" \
    "$avg" "$min" "$max" "$n" \
    "$loss" "$rtt" "$tq" "$tput" \
    "$chan" "$width" "$note" >>"$out"

  cat <<-EOF

	  distance     ${distance_m} m    bandwidth ${BW_MHZ:-?} MHz    height ${HEIGHT_M:-?} m
	  RSSI         ${avg} dBm  (min ${min}, max ${max}, n=${n})
	  packet loss  ${loss}%
	  rtt avg      ${rtt:-n/a} ms
	  batman TQ    ${tq:-n/a} / 255
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
# `walk` -- continuous trace until the link dies
# --------------------------------------------------------------------------

# Run on the STATIONARY node. Nothing here knows how far away the walker is:
# type a note and press Enter at any point -- "200 m", "past the treeline" --
# and it lands on the next row. Otherwise correlate elapsed_s against a GPS
# track afterwards.

WALK_OUT=
START_EPOCH=0
STATE=up
CONSEC_FAIL=0
LOSS_STARTED_AT=

# Last sample where the link was demonstrably alive.
LAST_GOOD_ELAPSED=
LAST_GOOD_RSSI=
LAST_GOOD_NOTE=

# Worst RSSI still carrying traffic -- the practical sensitivity floor for this
# bandwidth, and the number the whole range budget rests on.
MIN_GOOD_RSSI=

EVENTS=()

# Non-blocking: pick up an operator note if one has been typed, without ever
# stalling the sampling loop waiting for input.
read_note() {
  local line=
  if [[ -t 0 ]]; then
    IFS= read -r -t 0.01 line 2>/dev/null || true
  fi
  printf '%s' "${line:-}"
}

walk_summary() {
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  printf '\n' >&2
  cat >&2 <<-EOF
	  ---- walk test summary ----
	  bandwidth        ${BW_MHZ:-?} MHz    antenna height ${HEIGHT_M:-?} m
	  duration         $(($(date +%s) - START_EPOCH))s
	  final state      $STATE
	  last good at     ${LAST_GOOD_ELAPSED:-n/a}s elapsed, RSSI ${LAST_GOOD_RSSI:-n/a} dBm
	  weakest working  ${MIN_GOOD_RSSI:-n/a} dBm
	  last good note   ${LAST_GOOD_NOTE:-none}
	  csv              $WALK_OUT
	EOF

  if [[ ${#EVENTS[@]} -gt 0 ]]; then
    printf '  events\n' >&2
    printf '    %s\n' "${EVENTS[@]}" >&2
  fi

  printf '\n  Weakest working RSSI is the practical sensitivity floor at this\n' >&2
  printf '  bandwidth. Budget 15-20 dB above it for a link you intend to rely on.\n\n' >&2

  printf '# %s end state=%s last_good_elapsed=%s last_good_rssi=%s min_good_rssi=%s\n' \
    "$now" "$STATE" "${LAST_GOOD_ELAPSED:-}" "${LAST_GOOD_RSSI:-}" "${MIN_GOOD_RSSI:-}" \
    >>"$WALK_OUT"
}

mode_walk() {
  preflight

  WALK_OUT=${OUT:-$ROOT/walktest.csv}

  local pingif
  pingif=$(ping_iface "$IFACE" "$MESHIF")

  if [[ ! -f $WALK_OUT ]]; then
    echo "timestamp,elapsed_s,state,rssi,tx_bitrate_mbps,batman_tq,ping_ok,rtt_ms,bw_mhz,height_m,note" \
      >"$WALK_OUT"
  fi

  START_EPOCH=$(date +%s)
  trap 'walk_summary; exit 0' INT TERM

  log "sampling every ${SAMPLE_INTERVAL}s over $pingif -> $PEER"
  log "type a note + Enter to annotate a row; Ctrl-C to finish"

  while :; do
    local ts elapsed rssi rate tq note ping_ok rtt out
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    elapsed=$(($(date +%s) - START_EPOCH))

    rssi=$(sample_rssi "$IFACE" "$PEER_MAC")
    rate=$(sample_bitrate "$IFACE")
    tq=$(sample_tq "$MESHIF")
    note=$(read_note)

    # Keep the probe's RTT rather than only its exit status. It costs nothing --
    # the ping already ran -- and latency degrading before loss appears is the
    # earliest sign of a link going marginal, which is precisely what a walk is
    # looking for.
    rtt=
    if out=$(ping -I "$pingif" -c 1 -W "$PING_TIMEOUT" "$PEER" 2>/dev/null); then
      ping_ok=1
      rtt=$(printf '%s' "$out" |
        awk -F'time=' '/time=/{split($2, a, " "); print a[1]; exit}')
    else
      ping_ok=0
    fi

    # Ping is the authority on whether the link carries traffic: a station can
    # linger in `iw station dump` well after it stops being reachable.
    if [[ $ping_ok == 1 ]]; then
      CONSEC_FAIL=0
      if [[ -n $rssi ]]; then
        LAST_GOOD_ELAPSED=$elapsed
        LAST_GOOD_RSSI=$rssi
        [[ -n $note ]] && LAST_GOOD_NOTE=$note
        if [[ -z $MIN_GOOD_RSSI ]] || ((rssi < MIN_GOOD_RSSI)); then
          MIN_GOOD_RSSI=$rssi
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

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,"%s"\n' \
      "$ts" "$elapsed" "$STATE" "${rssi:-}" "${rate:-}" "${tq:-}" \
      "$ping_ok" "${rtt:-}" "$BW_MHZ" "$HEIGHT_M" "$note" >>"$WALK_OUT"

    printf '\r  %5ss  %-4s  rssi %-5s  rate %-5s  tq %-4s  rtt %-6s  ping %s   ' \
      "$elapsed" "$STATE" "${rssi:-n/a}" "${rate:-n/a}" "${tq:-n/a}" \
      "${rtt:-n/a}" "$ping_ok" >&2

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

case "${1:-}" in
at)
  shift
  mode_at "$@"
  ;;
walk)
  shift
  mode_walk "$@"
  ;;
*) usage ;;
esac
