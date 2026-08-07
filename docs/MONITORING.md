# Measuring and Monitoring the Mesh

`batman_oracle.sh` is the one diagnostics tool: fleet status, careful
measurements at a surveyed distance, throughput runs, walk traces, and
unattended long-run logging. No Prometheus, no daemons, no agent on the nodes --
just timestamped rows appended to files that you process **offline**.

Two ideas run through all of it.

**The oracle is a remote control head, not a node.** It is normally run from a
laptop plugged into the router's Ethernet, and that laptop has no HaLow radio
and no `bat0`. So every reading -- RSSI, station counters, the originator table,
and above all the ping -- is taken *on* a node over ssh. A ping issued by the
laptop would traverse Ethernet and the router before touching a radio, and
would report a number that says nothing about the hop under test. Running the
oracle on a Jetson is the same code path with the ssh hop elided.

**Passive and active measurements must be kept apart.** Passive metrics observe
the network without changing it. Active ones inject traffic and therefore
perturb the very thing being measured. This matters far more here than on
ordinary WiFi, and section 2 is about why.

---

## 1. What it measures

| Layer | Metric | Source | Type |
| --- | --- | --- | --- |
| Mesh | TQ (0-255), next hop, originator count | `batctl originators` | passive |
| Mesh | packet / forward / mgmt counters | `batctl statistics` | passive |
| Radio | RSSI, signal avg, beacon signal | `iw station dump` | passive |
| Radio | PHY rate, MCS, expected throughput | `iw station dump` | passive |
| Radio | tx retries, tx failed, rx drop misc | `iw station dump` | passive |
| Radio | noise floor, channel active/busy time | `iw survey dump` | passive |
| PHY | temperature and vendor counters | `morse_cli stats` | passive |
| Clock | current sync offset, skew, stratum | `chronyc tracking` | passive |
| L3 | round-trip latency | `ping` | active (tiny) |
| L4 | throughput | `iperf3` | active (heavy) |

The passive set is cheap and safe to leave running for a whole deployment.

### The fields that were missing before

The old `walk` recorded eleven columns: RSSI, negotiated rate, TQ, whether a
ping came back, and the inputs. That is enough to find where a link dies and
not much else. The wide row now written by `walk` and `soak` adds:

- **tx retries / tx failed, and a per-interval retry rate.** A link degrades by
  retrying long before it starts losing pings. This is the earliest warning
  there is, and the raw counters alone do not show it -- they are monotonic
  since association, so the tool differences them between samples.
- **noise floor, and the SNR derived from it.** SNR is what actually predicts
  whether a rate can be held. A bare RSSI does not: -90 dBm is a fine link at a
  -105 dBm noise floor and a dead one at -92.
- **channel active and busy time.** This separates "the link got worse" from
  "something else started transmitting", which are indistinguishable in RSSI
  and have completely different remedies. At 1 MHz there is very little airtime
  to go around, so this is not an exotic case.
- **next hop and a direct-vs-relayed flag.** A TQ that improves because
  batman-adv started relaying through a third node is not the same result as a
  link that got better, and the bare number cannot tell you which happened.
- **clock offset and stratum, per sample.** A run whose sync degraded partway
  is still usable if you can see exactly where.

There is deliberately **no in-band annotation**. The old walk let you type a
note and press Enter to have it land on the next row; that is gone. Keep
distances in a notebook and correlate against `elapsed_s` afterwards. Typing
into the terminal that is driving the sampler is a good way to drop a sample.

---

## 2. Active measurement is expensive here

On 20 MHz 802.11n, a 2 Hz ping and a ten-second iperf3 burst every five minutes
are rounding errors. At 1 MHz S1G they are not.

MCS0 at 1 MHz is **0.3 Mbps**, and 8 MHz only reaches 3.3 Mbps (see the
bandwidth table in [OPENWRT.md](OPENWRT.md)). A throughput burst does not
perturb a link that narrow, it *saturates* it. Every passive number sampled
during a burst -- RSSI is fine, but retry rate, busy time, TQ and latency are
not -- describes a link under load rather than the link you are deploying.

Three consequences, all of them baked into the defaults:

- **`at` and `tp` are separate modes** writing to separate CSVs, rather than one
  mode with a flag. `at` observes; `tp` loads. Splitting them in the tool is
  what stops the two being averaged together six months from now.
- **`soak` does no throughput at all** unless `SOAK_THROUGHPUT=1`.
- **Throughput is one pair at a time, and one node at a time.** In a shared
  medium concurrent flows contend for airtime and corrupt each other's numbers.
  `soak` serialises pairs within a node but *cannot* coordinate across nodes --
  if every Jetson runs its own soak with throughput on, the bursts collide.
  Run throughput from one node only.

---

## 3. Clock sync

Timestamps from different nodes are joinable only if the clocks agree. `soak`
enforces this: it will not write a line until `chronyc` reports the node synced
to within `SYNC_MAX_OFFSET` (default 50 ms). Set `REQUIRE_SYNC=0` to downgrade
that to a warning, and accept that the resulting files may not line up.

The transport is a non-issue -- `bat0` is an ordinary L3 interface, NTP is
unicast UDP/123, and the mesh is one L2 segment so every node shares a subnet.
What has to be designed is **authority** and **the epoch jump**.

### Authority

The gateway is the only node with an uplink, so it is the only one that can
know the real time. `install_network_stack.sh` writes
`/etc/chrony/conf.d/halow-mesh.conf` pointing every Jetson at the gateway's
**derived** mesh address -- the same EUI-64 derivation as every other address,
so a `ULA_PREFIX` change moves the time source with the fleet.

Serving time from the router is [OPENWRT.md section 5C](OPENWRT.md). Read the
offline case there: busybox `sysntpd` refuses to serve time it does not have,
so a deployment that must work with no uplink needs real chrony with
`local stratum 10` on the router.

If every node can boot to 1970 and none is authoritative, they will happily
agree on a *wrong* time. That is worse than it sounds only in one specific way:
it is undetectable from inside.

### The epoch jump

The Orin Nano has no working RTC and boots to the Unix epoch. Two pieces
address it:

- **`makestep 1 -1`** in the drop-in. By default chrony steps the clock only
  for its first few updates and slews afterwards -- and slewing a 56-year
  offset would never finish. `1 -1` means "step whenever the offset exceeds
  1 s, with no limit on how many times", so a node that boots at 1970, or drops
  out and rejoins hours later, jumps straight to the correct time.
- **`fake-hwclock`**, installed by `build_dependencies.sh` and saved once by
  the installer. It writes the system time to disk periodically and restores it
  at boot, so the node comes up at "a few minutes ago" rather than 1970. An
  effectively stale-but-sane software RTC, which shrinks chrony's first
  correction from a 56-year leap to something small and safe.

`systemd-timesyncd` is masked by the installer. It and chrony both want to
discipline the clock and will fight over it -- the same class of collision as
avahi against systemd-resolved, and the same remedy.

### The cost, and what it breaks

`makestep 1 -1` means the wall clock can jump **backward** at any time. That
breaks duration arithmetic, timers, and TF mid-run.

- Measure elapsed intervals with **`CLOCK_MONOTONIC`** (ROS: steady time). Never
  with wall time. The oracle uses wall time only for cross-node *timestamps*,
  which is exactly and only what it is safe for.
- Sequence startup: bring up `bat0`, let batman converge, let chrony take its
  first step, and only **then** launch the robot stack. A systemd unit with
  `After=chrony-wait.service`, or a gate:

```sh
chronyc waitsync 30 0.05   # up to ~30 tries for offset < 50 ms
```

Over HaLow, realistic sync is **low single-digit milliseconds**. Fine for
correlating logs; not for anything tighter.

---

## 4. Running it

Every mode takes `NODE` (the node to measure from) and most take `PEER` (the
node to measure to). Both are roster names from `etc/bat-hosts`; the tool
derives their addresses, so nothing needs a working resolver at either end.

On a Jetson, `NODE` defaults to that machine. From the laptop it must be named.

```sh
# whole-fleet health, from the laptop
./batman_oracle.sh status

# one careful passive measurement at a surveyed distance
NODE=olo PEER=wazza BW_MHZ=1 HEIGHT_M=4 ./batman_oracle.sh at 750 "clear LOS, dry"

# an active throughput run at that same position
NODE=olo PEER=wazza BW_MHZ=1 HEIGHT_M=4 ./batman_oracle.sh tp 750

# continuous trace while the other node walks away; NODE is the STATIONARY one
NODE=olo PEER=wazza BW_MHZ=1 HEIGHT_M=4 ./batman_oracle.sh walk

# unattended logging against the rest of the roster
NODE=olo ./batman_oracle.sh soak

# the fleet's /etc/hosts block, for the laptop and the router
./batman_oracle.sh hosts
```

`BW_MHZ` and `HEIGHT_M` are **recorded verbatim, not measured**. The driver
reports S1G channels as their 5 GHz equivalents so the real bandwidth is not
readable, and antenna height dominates path loss -- a row without it cannot be
compared against any other row. Record height every time.

Bandwidth changes need both ends reconfigured, so a sweep means walking back.
Do every bandwidth at one position before moving.

### `tp` specifics

`tp` tests **both directions** by default. Asymmetry is common: the two ends
have different noise floors, and once the antennas are at different heights
they genuinely have different links.

It starts a one-shot `iperf3 -s -1` on the peer for the duration, so there is
nothing to clean up and nothing left listening on a node that is about to be
carried out of range. Set `TP_AUTOSERVER=0` if you run your own server.

A probe is taken immediately before and after the run, so the row carries the
RSSI, TQ and busy figures that held going in, plus the retry rate *during* the
transfer. A throughput number without those cannot be compared against a number
taken on a different day.

---

## 5. Output

| File | Written by | Contents |
| --- | --- | --- |
| `rangetest.csv` | `at` | one row per surveyed position |
| `throughput.csv` | `tp` | one row per throughput run, both directions |
| `walktest.csv` | `walk` | the wide sample row, one per interval |
| `oracle-logs/soak_<node>/samples_<node>.csv` | `soak` | the same wide row |
| `oracle-logs/soak_<node>/originators_<node>.csv` | `soak` | `ts,node,originator,tq,nexthop,last_seen_s,best` |
| `oracle-logs/soak_<node>/batstats_<node>.csv` | `soak` | `ts,node,metric,value` (long format) |
| `oracle-logs/soak_<node>/probes_<node>.log` | `soak` | raw delimited tool output |
| `oracle-logs/soak_<node>/meta_<node>.txt` | `soak` | versions, peers, chrony state at start |
| `oracle-logs/<stamp>_*.{probes,json,ping,...}` | `at`, `tp` | raw output per run |

`walk` and `soak` share one column list, so a parser written for one reads the
other.

Two deliberate choices worth knowing:

**The raw tool output is always kept**, alongside the parsed CSV. `iw` and
`batctl` output formats vary between versions, and the parsers make assumptions
about column positions. If a mapping turns out wrong for your build, nothing is
lost and you can reparse offline.

**`batstats` is long format** -- one metric per row rather than one column per
counter. A new counter in a future `batctl` then adds rows instead of breaking
a column mapping.

Files past `MAX_FILE_MB` (default 100) are rotated to `<name>.<epoch>.rot`.
Concatenate the parts back together offline.

---

## 6. Offline analysis

Every row carries an epoch timestamp (`probe_ts`) taken on the node itself, so
alignment across nodes is a few `merge_asof` calls -- which is the entire reason
section 3 exists.

```python
import pandas as pd, glob

def load(path):
    df = pd.read_csv(path)
    df["probe_ts"] = pd.to_datetime(df["probe_ts"], unit="s")
    return df.sort_values("probe_ts")

samples = pd.concat(load(f) for f in glob.glob("oracle-logs/soak_*/samples_*.csv"))
origs   = pd.concat(load(f) for f in glob.glob("oracle-logs/soak_*/originators_*.csv"))

# attach the route that held at each radio sample
merged = pd.merge_asof(
    samples.sort_values("probe_ts"), origs.sort_values("probe_ts"),
    on="probe_ts", direction="backward", tolerance=pd.Timedelta("2s"),
)
```

If the nodes are **moving**, log position or odometry too, against the same
synced clock. Link quality tracks geometry, and without it a soak tells you
that the link got worse but never where anything was.

---

## 7. Reading a walk

The number to take away is **weakest working RSSI**: the lowest signal that was
still carrying traffic. That is the practical sensitivity floor at that
bandwidth, and the whole range budget rests on it. Budget **15-20 dB above it**
for a link you intend to rely on.

Check peak channel busy before concluding anything about path loss. A walk that
ends in a built-up area can look like a range limit when it is contention.

Ping, not the station dump, is the authority on whether a link carries traffic:
a station lingers in `iw station dump` well after it stops being reachable.
This is why `walk` requires `LOSS_HOLD` consecutive failures (default 5) before
declaring the link down -- one dropped ping at range is normal, several in a row
is a cutoff.

Finally: **do not bench-test these radios on the same desk.** At 1 m the
received level is around -8 dBm and the front end saturates -- peering succeeds
while every data frame fails, which reads as a broken driver rather than as too
much signal. The tool warns above -25 dBm. Treat any RSSI taken at short range
as meaningless for range planning.

---

## 8. Checklist

- [ ] `chrony`, `fake-hwclock`, `iperf3`, `ethtool` on every Jetson
      (`./build_dependencies.sh`)
- [ ] router serving NTP, and `chrony` there if the mesh must work offline
      ([OPENWRT.md 5C](OPENWRT.md))
- [ ] `chronyc tracking` shows a small offset on every node before trusting any log
- [ ] laptop routed to the mesh, not bridged ([OPENWRT.md 5D](OPENWRT.md))
- [ ] ssh keys on every node, so `BatchMode` ssh works without a prompt
- [ ] `./batman_oracle.sh status` green across the fleet
- [ ] `BW_MHZ` and `HEIGHT_M` set on every measurement run
- [ ] robot stack started **after** chrony's first step
