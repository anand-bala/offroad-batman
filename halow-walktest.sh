#!/usr/bin/env bash
#
# halow-walktest.sh -- log link quality continuously while one node walks away,
# and record where it drops.
#
# Run this on the STATIONARY node. It samples once a second until interrupted,
# and reports the last known-good signal at the moment the link is lost.
#
#   sudo PEER=node2 ./halow-walktest.sh
#   sudo PEER=node2 BW_MHZ=1 HEIGHT_M=4 OUT=walk-1mhz.csv ./halow-walktest.sh
#
# Nothing here knows how far away the walker is. Type a note and press Enter at
# any point -- "200 m", "past the treeline" -- and it lands on the next row.
# Otherwise correlate elapsed_s against a GPS track afterwards.
#
# Ctrl-C for the summary. Complements halow-rangetest.sh, which takes one
# careful measurement at a known distance; this one trades precision for a
# continuous trace of where the link actually dies.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=node-id.sh
source "$ROOT/node-id.sh"

# --------------------------------------------------------------------------

# Auto-detected by driver, so it works before and after the 10-halow.link
# rename. Set IFACE explicitly to override.
IFACE=${IFACE:-$(morse_iface)}
IFACE=${IFACE:-wlan0}
MESHIF=${MESHIF:-bat0}

PEER=${PEER:-}
PEER_MAC=${PEER_MAC:-}

SAMPLE_INTERVAL=${SAMPLE_INTERVAL:-1}

# Consecutive failed probes before calling the link down. One dropped ping at
# range is normal; several in a row is a cutoff. Raising this makes the script
# slower to declare loss but less prone to calling it early on a deep fade.
LOSS_HOLD=${LOSS_HOLD:-5}

# Stop after this many seconds of continuous loss. 0 runs until Ctrl-C, which
# is what you want if you expect the walker to come back into range.
EXIT_AFTER_LOSS=${EXIT_AFTER_LOSS:-0}

# Per-probe ping timeout, seconds. Keep it under SAMPLE_INTERVAL.
PING_TIMEOUT=${PING_TIMEOUT:-1}

BW_MHZ=${BW_MHZ:-}
HEIGHT_M=${HEIGHT_M:-}

OUT=${OUT:-$ROOT/walktest.csv}
LOGDIR=${LOGDIR:-$ROOT/rangetest-logs}

# --------------------------------------------------------------------------

log() { printf '[walktest] %s\n' "$*" >&2; }
die() { printf '[walktest] ERROR: %s\n' "$*" >&2; exit 1; }

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

preflight() {
  [[ $EUID -eq 0 ]] || die "must run as root"
  [[ -n $PEER ]] || die "set PEER to the peer's IP or hostname"
  command -v iw >/dev/null || die "iw not found"
  ip link show "$IFACE" >/dev/null 2>&1 || die "$IFACE does not exist"
  mkdir -p "$LOGDIR"
}

sample_rssi() {
  local dump
  dump=$(iw dev "$IFACE" station dump 2>/dev/null || true)
  if [[ -n $PEER_MAC ]]; then
    printf '%s' "$dump" | awk -v mac="$PEER_MAC" '
      tolower($0) ~ "^station " tolower(mac) {want=1; next}
      /^Station/ {want=0}
      want && /signal:/ {print $2; exit}'
  else
    printf '%s' "$dump" | awk '/signal:/ {print $2; exit}'
  fi
}

sample_bitrate() {
  iw dev "$IFACE" station dump 2>/dev/null \
    | awk '/tx bitrate:/ {print $3; exit}' || true
}

sample_tq() {
  command -v batctl >/dev/null || return 0
  ip link show "$MESHIF" >/dev/null 2>&1 || return 0
  batctl meshif "$MESHIF" originators 2>/dev/null \
    | awk '{ if (match($0, /\([ ]*[0-9]+\)/)) {
               v=substr($0, RSTART+1, RLENGTH-2); gsub(/ /,"",v);
               if (v+0 > best) best=v+0 } }
           END {if (best) print best}' || true
}

# Non-blocking: pick up an operator note if one has been typed, without ever
# stalling the sampling loop waiting for input.
read_note() {
  local line=
  if [[ -t 0 ]]; then
    IFS= read -r -t 0.01 line 2>/dev/null || true
  fi
  printf '%s' "${line:-}"
}

summary() {
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  printf '\n' >&2
  cat >&2 <<-EOF
	  ---- walk test summary ----
	  bandwidth        ${BW_MHZ:-?} MHz    antenna height ${HEIGHT_M:-?} m
	  duration         $(( $(date +%s) - START_EPOCH ))s
	  final state      $STATE
	  last good at     ${LAST_GOOD_ELAPSED:-n/a}s elapsed, RSSI ${LAST_GOOD_RSSI:-n/a} dBm
	  weakest working  ${MIN_GOOD_RSSI:-n/a} dBm
	  last good note   ${LAST_GOOD_NOTE:-none}
	  csv              $OUT
	EOF

  if [[ ${#EVENTS[@]} -gt 0 ]]; then
    printf '  events\n' >&2
    printf '    %s\n' "${EVENTS[@]}" >&2
  fi

  printf '\n  Weakest working RSSI is the practical sensitivity floor at this\n' >&2
  printf '  bandwidth. Budget 15-20 dB above it for a link you intend to rely on.\n\n' >&2

  printf '# %s end state=%s last_good_elapsed=%s last_good_rssi=%s min_good_rssi=%s\n' \
    "$now" "$STATE" "${LAST_GOOD_ELAPSED:-}" "${LAST_GOOD_RSSI:-}" "${MIN_GOOD_RSSI:-}" \
    >> "$OUT"
}

main() {
  preflight

  local pingif=$IFACE
  ip link show "$MESHIF" >/dev/null 2>&1 && pingif=$MESHIF

  if [[ ! -f $OUT ]]; then
    echo "timestamp,elapsed_s,state,rssi,tx_bitrate_mbps,batman_tq,ping_ok,bw_mhz,height_m,note" \
      > "$OUT"
  fi

  START_EPOCH=$(date +%s)
  trap 'summary; exit 0' INT TERM

  log "sampling every ${SAMPLE_INTERVAL}s over $pingif -> $PEER"
  log "type a note + Enter to annotate a row; Ctrl-C to finish"

  while :; do
    local ts elapsed rssi rate tq note ping_ok
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    elapsed=$(( $(date +%s) - START_EPOCH ))

    rssi=$(sample_rssi)
    rate=$(sample_bitrate)
    tq=$(sample_tq)
    note=$(read_note)

    if ping -I "$pingif" -c 1 -W "$PING_TIMEOUT" -q "$PEER" >/dev/null 2>&1; then
      ping_ok=1
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
        if [[ -z $MIN_GOOD_RSSI ]] || (( rssi < MIN_GOOD_RSSI )); then
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

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,"%s"\n' \
      "$ts" "$elapsed" "$STATE" "${rssi:-}" "${rate:-}" "${tq:-}" \
      "$ping_ok" "$BW_MHZ" "$HEIGHT_M" "$note" >> "$OUT"

    printf '\r  %5ss  %-4s  rssi %-5s  rate %-5s  tq %-4s  ping %s   ' \
      "$elapsed" "$STATE" "${rssi:-n/a}" "${rate:-n/a}" "${tq:-n/a}" "$ping_ok" >&2

    if [[ $STATE == down && $EXIT_AFTER_LOSS -gt 0 && -n $LOSS_STARTED_AT ]]; then
      if (( elapsed - LOSS_STARTED_AT >= EXIT_AFTER_LOSS )); then
        log "down for ${EXIT_AFTER_LOSS}s; stopping"
        summary
        exit 0
      fi
    fi

    sleep "$SAMPLE_INTERVAL"
  done
}

main "$@"
