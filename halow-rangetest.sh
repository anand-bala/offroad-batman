#!/usr/bin/env bash
#
# halow-rangetest.sh -- record link quality at a known distance, append to CSV.
#
# Run one measurement per position, on the node you are standing at, with the
# peer already up. Distance is an argument because nothing on the node can know
# it; everything else is measured.
#
#   sudo PEER=192.168.60.2 ./halow-rangetest.sh 750
#   sudo PEER=node2 BW_MHZ=1 HEIGHT_M=4 ./halow-rangetest.sh 750 "clear LOS, dry"
#
# Bandwidth changes need BOTH ends reconfigured, so a sweep means walking back.
# Plan positions around that: do every bandwidth at one distance before moving.
#
# Results append to rangetest.csv; raw tool output goes to rangetest-logs/ so a
# run can be re-examined without repeating the walk.

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

# Peer to ping. Hostname works if /etc/hosts is populated.
PEER=${PEER:-}

# Restrict RSSI sampling to one peer. Empty means "first station listed",
# which is what you want with exactly two nodes up.
PEER_MAC=${PEER_MAC:-}

# RSSI fluctuates several dB outdoors -- a single reading is noise, not a
# measurement. Sample across a window and keep the spread.
SAMPLES=${SAMPLES:-30}
SAMPLE_INTERVAL=${SAMPLE_INTERVAL:-1}

PING_COUNT=${PING_COUNT:-100}
PING_INTERVAL=${PING_INTERVAL:-0.2}

# Throughput needs `iperf3 -s` running on the peer. Off by default: it costs
# airtime and a battery, and RSSI plus loss already answers "does this work".
IPERF=${IPERF:-0}
IPERF_TIME=${IPERF_TIME:-10}

# Recorded verbatim, not measured. Antenna height dominates path loss, so a
# row without it cannot be compared against any other row.
HEIGHT_M=${HEIGHT_M:-}
BW_MHZ=${BW_MHZ:-}

OUT=${OUT:-$ROOT/rangetest.csv}
LOGDIR=${LOGDIR:-$ROOT/rangetest-logs}

# --------------------------------------------------------------------------

log() { printf '[rangetest] %s\n' "$*" >&2; }
die() { printf '[rangetest] ERROR: %s\n' "$*" >&2; exit 1; }

DISTANCE_M=${1:-}
NOTE=${2:-}

usage() {
  printf 'usage: PEER=<ip|host> %s <distance_m> [note]\n' "$0" >&2
  exit 2
}

preflight() {
  [[ -n $DISTANCE_M ]] || usage
  [[ $DISTANCE_M =~ ^[0-9]+$ ]] || die "distance must be a whole number of metres"
  [[ $EUID -eq 0 ]] || die "must run as root (ping interval, iw access)"
  [[ -n $PEER ]] || die "set PEER to the peer's IP or hostname"

  command -v iw >/dev/null || die "iw not found"
  ip link show "$IFACE" >/dev/null 2>&1 || die "$IFACE does not exist"

  iw dev "$IFACE" station dump 2>/dev/null | grep -q '^Station' \
    || die "no peers on $IFACE -- bring the link up before measuring"

  mkdir -p "$LOGDIR"
}

# Pull the signal figure for the peer of interest. `iw` prints e.g.
#	signal:  	-52 [-53, -60] dBm
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

collect_rssi() {
  local i v
  for ((i = 0; i < SAMPLES; i++)); do
    v=$(sample_rssi)
    [[ -n $v ]] && printf '%s\n' "$v"
    sleep "$SAMPLE_INTERVAL"
  done
}

main() {
  preflight

  local stamp base
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  base="$LOGDIR/${stamp}_${DISTANCE_M}m"

  # Radio state, verbatim. Recall the driver reports S1G channels as their 5GHz
  # equivalents, so this is a 5GHz-looking channel/width -- BW_MHZ carries the
  # real sub-1GHz figure, which is why it is an input rather than a reading.
  iw dev "$IFACE" info > "$base.iw-info" 2>&1 || true
  local chan width
  chan=$(awk '/^\tchannel /{print $2; exit}' "$base.iw-info" 2>/dev/null || true)
  width=$(awk -F'width: ' '/width:/{split($2,a,","); print a[1]; exit}' \
          "$base.iw-info" 2>/dev/null || true)

  log "sampling RSSI for $((SAMPLES * SAMPLE_INTERVAL))s..."
  collect_rssi > "$base.rssi"

  local n avg min max
  read -r n avg min max <<<"$(awk '
    NR==1 {min=$1; max=$1}
    {sum+=$1; if ($1<min) min=$1; if ($1>max) max=$1; n++}
    END {if (n) printf "%d %.1f %d %d", n, sum/n, min, max; else print "0 0 0 0"}
  ' "$base.rssi")"

  [[ $n -gt 0 ]] || die "no RSSI samples captured -- did the link drop?"

  # The lesson from bench testing: a very strong signal saturates the receiver
  # and looks like a driver fault. Unlikely outdoors, but flag it rather than
  # let it silently poison a data set.
  awk -v a="$avg" 'BEGIN {exit !(a > -25)}' \
    && log "WARNING: mean RSSI ${avg} dBm is implausibly strong; check attenuation"

  log "pinging $PEER ($PING_COUNT packets)..."
  local pingif=$IFACE
  ip link show "$MESHIF" >/dev/null 2>&1 && pingif=$MESHIF

  ping -I "$pingif" -c "$PING_COUNT" -i "$PING_INTERVAL" -q "$PEER" \
    > "$base.ping" 2>&1 || true

  local loss rtt
  loss=$(awk -F'[ %]' '/packet loss/{for(i=1;i<=NF;i++) if($i=="packet") print $(i-2)}' \
         "$base.ping" | head -1)
  rtt=$(awk -F'/' '/^(rtt|round-trip)/{print $5; exit}' "$base.ping")
  loss=${loss:-100}
  rtt=${rtt:-}

  # batman link quality, 0-255. Only meaningful once bat0 is up.
  local tq=
  if command -v batctl >/dev/null && ip link show "$MESHIF" >/dev/null 2>&1; then
    batctl meshif "$MESHIF" originators > "$base.originators" 2>&1 || true
    tq=$(awk '{ if (match($0, /\([ ]*[0-9]+\)/)) {
                  v=substr($0, RSTART+1, RLENGTH-2); gsub(/ /,"",v);
                  if (v+0 > best) best=v+0 } }
              END {if (best) print best}' "$base.originators" 2>/dev/null || true)
  fi

  local tput=
  if [[ $IPERF == 1 ]]; then
    log "iperf3 to $PEER for ${IPERF_TIME}s..."
    iperf3 -c "$PEER" -t "$IPERF_TIME" -J > "$base.iperf.json" 2>&1 || true
    tput=$(awk -F'[:,]' '/"bits_per_second"/{v=$2} END {if (v) printf "%.3f", v/1e6}' \
           "$base.iperf.json" 2>/dev/null || true)
  fi

  morse_cli -i "$IFACE" stats > "$base.morse-stats" 2>&1 || true

  if [[ ! -f $OUT ]]; then
    echo "timestamp,distance_m,bw_mhz,height_m,rssi_avg,rssi_min,rssi_max,samples,loss_pct,rtt_ms,batman_tq,mbps,channel,width,note" \
      > "$OUT"
  fi

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,"%s"\n' \
    "$stamp" "$DISTANCE_M" "$BW_MHZ" "$HEIGHT_M" \
    "$avg" "$min" "$max" "$n" \
    "$loss" "$rtt" "$tq" "$tput" \
    "$chan" "$width" "$NOTE" >> "$OUT"

  cat <<-EOF

	  distance     ${DISTANCE_M} m    bandwidth ${BW_MHZ:-?} MHz    height ${HEIGHT_M:-?} m
	  RSSI         ${avg} dBm  (min ${min}, max ${max}, n=${n})
	  packet loss  ${loss}%
	  rtt avg      ${rtt:-n/a} ms
	  batman TQ    ${tq:-n/a} / 255
	  throughput   ${tput:-n/a} Mbps
	  logs         ${base}.*
	  appended to  ${OUT}

	EOF

  # Deployment wants margin, not a link that merely passed once.
  if [[ ${loss%.*} -gt 0 ]]; then
    log "NOTE: non-zero loss at this position -- not a usable hop"
  fi
}

main "$@"
