# MM8108 Driver Setup

Builds and installs the Morse Micro MM8108 (802.11ah / HaLow) stack on an Ubuntu device.

NOTE: Does not cross-compile and is expected to be run directly on the target device.

The card is driven over USB (`CONFIG_MORSE_USB`),
which is what the GW16167 M.2 2230 E-key module uses.
If the card does not appear, check the link before the driver:
`lsusb -d 325b:` should show `325b:8100`.
Not every M.2 E-key slot wires up USB 2.0,
and the driver cannot see a card that is only on PCIe lanes.

## Install

```sh
git clone --recurse-submodules <this repo>
cd morse-micro
./morse/morse_micro_install.sh
```

The repo holds two independently installable packages -- `morse/` for the driver stack
and `batman/` for the mesh routing module -- each with its own `dkms.conf`,
plus the bring-up scripts at the root.
Neither install depends on the other;
a node that only needs the radio never has to build `batman-adv`.

Installs:

- `morse.ko` + `dot11ah.ko` via DKMS, so they rebuild on kernel upgrades
- firmware and BCFs into `/lib/firmware/morse`
- `hostapd_s1g`, `wpa_supplicant_s1g`, `morse_cli` and friends into `$BINDIR`

Environment overrides: `BINDIR` (default `/usr/local/sbin`) and `COUNTRY`
(default `US`, baked into both the module and `/etc/modprobe.d/morse.conf`).

Uninstall with `./morse/morse_micro_install.sh --uninstall`.
Removal is deliberately not a DKMS `POST_REMOVE` hook,
because DKMS removals are per-kernel
and would drop the firmware during routine old-kernel cleanup.

## Multi-Hop Networking

The target topology is four Jetson nodes plus one OpenWrt travel router acting
as the Starlink gateway, all reachable from each other over multiple hops,
with nodes free to move in and out of range.

That is built as IBSS (ad-hoc) at layer 2 with `batman-adv` doing the routing on top,
**not** 802.11s.
Two reasons:

- `batman-adv` handles node churn far better than 802.11s HWMP, which is the
  requirement here.
- 802.11s is not available on these Jetsons.
  `/proc/config.gz` reports `# CONFIG_MAC80211_MESH is not set`,
  so `morse.ko` compiles out `NL80211_IFTYPE_MESH_POINT` at `morse_driver/mac.c:7628`
  (guarded by `MESH_CONFIG_ENABLED` at `morse_driver/mac.h:41`).
  Rebuilding `morse.ko` alone cannot fix this -- it is a property of the `mac80211` it
  builds against.
  Getting 802.11s would mean rebuilding `mac80211` from L4T kernel source,
  or a backports tree, and then rebuilding the driver against that.
  See [The 802.11s fallback](#the-80211s-fallback).

Note that any `wpa_supplicant_s1g` built
before 2026-08-03 has no `CONFIG_MESH` regardless:
`write_hostap_config` took its option lists as space-joined scalars and iterated them
as arrays, so every `sed` missed and both daemons were built straight from `defconfig`.
Fixed now, but binaries predating the fix are missing all the `WPA_S_ENABLE` /
`HOSTAPD_ENABLE` options and need a rebuild.
`CONFIG_SAE` and `CONFIG_IBSS_RSN` are on in `defconfig` already,
so the IBSS path works on either build.

### Interface Naming

The card is USB, so predictable naming hands it a MAC-derived name like
`wlx0cbf74005bc8` -- different on every node, which makes shared scripts and
config impossible. `10-halow.link` renames it:

```sh
sudo install -m 0644 10-halow.link /etc/systemd/network/10-halow.link
sudo udevadm control --reload
# reboot, or unplug/replug the card
```

Verify without rebooting:

```sh
udevadm test-builtin net_setup_link /sys/class/net/<iface>
```

**The name is `halow0`, not `wlan0`.** systemd warns against renaming into the
kernel's own namespace (`eth*`, `wlan*`): the kernel may hand that name to
another device before the rename lands, and the rename then fails
*intermittently* -- a poor failure mode on a node you cannot reach. `halow0` is
outside that namespace and cannot collide.

The cost is that `morse_cli` defaults to `wlan0`, so by-hand invocations need
`-i halow0`. Every script here already passes `-i "$IFACE"`, so they are
unaffected.

The file matches on `Driver=` rather than MAC, which is what lets one identical
file go on all four Jetsons. Confirm the driver name reported for the netdev
first -- it is usually the module name (`morse`), while the USB driver registers
separately as `morse_usb` (`morse/morse_driver/usb.c:1212`):

```sh
ethtool -i <iface> | head -2
udevadm info /sys/class/net/<iface> | grep -E 'ID_NET_DRIVER|DRIVERS='
```

Scripts do not depend on any of this: `IFACE` defaults to whichever netdev is
bound to a `morse*` driver (`morse_iface` in `node-id.sh`), so they work before
and after the rename, and on a node where it was never installed.

### Identity and Addressing

Two tables drive everything, identical on every node:

- `bat-hosts` -- MAC to name, installed to `/etc/bat-hosts`
- `hosts` -- name to `bat0` address, merged into `/etc/hosts`

A node works out which one it is from its own radio MAC, and both addresses
follow:

```
radio MAC -> bat-hosts -> name -> hosts -> bat0 IP -> last octet -> IBSS IP
```

So `0c:bf:74:00:5b:c8` becomes `olo.lan`, with `192.168.60.1/24` on `bat0` and
`192.168.50.1/24` on the radio. Adding a node is one line in each file and
nothing else; no per-node edits, no per-node invocation.

Fallbacks run in order -- `NODE_NAME` env, then MAC lookup, then the system
hostname -- and explicit `NODE_IP` / `BAT_IP` always win. Shared resolution
lives in `node-id.sh`, sourced by all four scripts, so they cannot disagree
about who this node is.

`/etc/hosts` is never overwritten. Only a marked block is replaced, so
`localhost` and anything the distro put there survive, and repeated runs are
idempotent.

Naming pays off twice. `batctl meshif bat0 originators` prints names instead of
hex, and `batctl meshif bat0 ping olo.lan` is an L2 ping that bypasses IP
entirely -- which separates "the mesh is broken" from "the addressing is
broken". Note the distro likely already has `127.0.1.1 olo` in `/etc/hosts`, so
prefer the unambiguous `.lan` names when you mean the mesh address.

### `halow-ibss.sh`

Brings an interface up in IBSS mode for bring-up and testing.
Not a production service -- nothing persists across a reboot, by design.

```sh
sudo DEBUG=1 ./halow-ibss.sh up   # open IBSS
sudo ./halow-ibss.sh up-rsn       # RSN-IBSS, needs PSK
sudo ./halow-ibss.sh status
sudo ./halow-ibss.sh down
```

Run identical parameters on every node. Nothing needs editing per node --
identity and addressing derive from the MAC; see
[Identity and addressing](#identity-and-addressing).

| Variable | Default | Notes |
| --- | --- | --- |
| `IFACE` / `PHY` | auto-detected / `phy0` | Found by driver; see [Interface naming](#interface-naming) |
| `SSID` | `HaLow-IBSS` | Must match fleet-wide |
| `CHANNEL` / `OP_CLASS` | `33` / `68` (1 MHz @ 918.5 MHz) | Must match fleet-wide |
| `FREQ` | unset | Fallback: emits `frequency=` instead of `channel`/`op_class` |
| `NODE_IP` | derived | From `hosts` via the node's MAC; override to force |
| `IBSS_SUBNET` | `192.168.50` | Subnet the derived IBSS address is built in |
| `NODE_NAME` | derived | Overrides MAC-based identity lookup |
| `PSK` | unset | `up-rsn` only; use `openssl rand -base64 24` |
| `DEBUG` | `0` | `1` runs the supplicant foreground with `-d`, and skips IP assignment |

Frequency mapping is `freq_MHz = 902 + 0.5 * channel`.
The driver reports S1G channels as their 5 GHz equivalents,
so `iw dev` showing `channel 100 (5500 MHz), width: 160 MHz`
for an 8 MHz S1G channel is expected.

The default is 1 MHz rather than the router's current 8 MHz -- see
[Range and bandwidth](#range-and-bandwidth) below.
Bandwidth is a fleet-wide decision; every node must match.

Two caveats.
The `channel`/`op_class` keys are documented by Gateworks only
for mesh (`mode=5`) network blocks, not IBSS -- if the supplicant rejects them,
set `FREQ` instead.
And S1G IBSS is lightly exercised by the vendor,
whose docs and kernel patches centre on 802.11s;
whether two nodes will hold an IBSS association is the open question the script exists
to answer.
The gate is `iw dev wlan0 station dump` listing the peer's MAC.
`iw dev wlan0 link` is not sufficient -- IBSS will form a cell of one
and look healthy with no peer.

### `halow-batman.sh`

Layers `batman-adv` over an IBSS interface.
Run `halow-ibss.sh up` first; this assumes `wlan0` is already in IBSS mode with a peer.
Same shape -- a bring-up harness, nothing persists across a reboot.

```sh
sudo ./halow-batman.sh up
sudo ./halow-batman.sh status
sudo ./halow-batman.sh down
```

| Variable | Default | Notes |
| --- | --- | --- |
| `IFACE` / `BATIF` | auto-detected / `bat0` | |
| `BAT_IP` | derived | From `hosts`; replaces the address on the radio |
| `BAT_HOSTS` | `./bat-hosts` | Installed to `/etc/bat-hosts`; empty to skip |
| `HOSTS` | `./hosts` | Merged into `/etc/hosts`; empty to skip |
| `GW_MODE` | `off` | `server` on the uplink node, `client` elsewhere |
| `ROUTING_ALGO` | `BATMAN_IV` | Must be set before the mesh interface exists |
| `HARD_MTU` | unset | e.g. `1532`, to keep `bat0` at a full 1500 |

**The script flushes the IP off `wlan0`.**
This is the behaviour most likely to surprise: `halow-ibss.sh` puts `NODE_IP` there,
but once `batman-adv` owns the interface it must carry no address of its own
or traffic takes the direct path and silently bypasses mesh routing.
Addressing moves to `bat0`,
on a separate subnet so it is obvious which layer is under test.
`down` tears down only the routing layer and leaves the IBSS up,
so the transport can be retested alone.

`BATMAN_IV` is the default deliberately.
`BATMAN_V` selects routes by estimated throughput,
which depends on the driver reporting sane rate information -- not an assumption worth
making on an S1G driver this new.

`batman-adv` adds ~28 bytes of header,
so `bat0` comes up around 1472 unless the hard interface goes to 1532.
Whether the Morse driver accepts an oversized MTU is untested,
hence opt-in via `HARD_MTU`.

Note `batman-adv` will happily form a mesh of one that looks entirely healthy
and forwards nothing, so the script warns when the IBSS has no peers.
The real check is `batctl meshif bat0 originators` listing the other nodes.

### `halow-rangetest.sh`

One measurement per position, appended to `rangetest.csv`. Intended for
outdoor field testing with the link already up.

```sh
sudo PEER=node2 BW_MHZ=1 HEIGHT_M=4 ./halow-rangetest.sh 750 "clear LOS, dry"
```

| Variable | Default | Notes |
| --- | --- | --- |
| `PEER` | *required* | IP or hostname to ping |
| `PEER_MAC` | unset | Restrict RSSI sampling; empty takes the first station |
| `SAMPLES` / `SAMPLE_INTERVAL` | `30` / `1` | RSSI sampling window, in seconds |
| `PING_COUNT` / `PING_INTERVAL` | `100` / `0.2` | |
| `IPERF` / `IPERF_TIME` | `0` / `10` | Needs `iperf3 -s` on the peer |
| `BW_MHZ`, `HEIGHT_M` | unset | Recorded verbatim, not measured |
| `OUT` / `LOGDIR` | `rangetest.csv` / `rangetest-logs/` | |

Distance is an argument and height/bandwidth are variables because the node
cannot know any of them. Record height every time -- it dominates path loss, so
a row without it cannot be compared against any other row.

**RSSI is sampled, not read once.** Outdoors a single reading varies by several
dB with multipath and motion, so the script takes 30 over 30 s and records
mean, min and max. The spread is often the more useful figure: a wide min/max
at distance means a marginal link even when the mean looks healthy.

All raw output -- `iw info`, the RSSI series, ping, originators,
`morse_cli stats`, iperf JSON -- is kept under `rangetest-logs/`, because
nobody wants to repeat a 750 m walk for one number that missed the CSV.

Two limitations. **Bandwidth changes need both ends reconfigured**, so do every
bandwidth at one position before moving. And **the reported TQ is the best
originator**, which is the peer only while exactly two nodes are up; with the
full fleet running, read `rangetest-logs/*.originators` instead.

### `halow-walktest.sh`

The continuous counterpart to `halow-rangetest.sh`: one node walks away while
this samples once a second and records where the link dies. Run it on the
**stationary** node.

```sh
sudo PEER=node2 BW_MHZ=1 HEIGHT_M=4 OUT=walk-1mhz.csv ./halow-walktest.sh
```

| Variable | Default | Notes |
| --- | --- | --- |
| `PEER` | *required* | IP or hostname |
| `SAMPLE_INTERVAL` | `1` | Seconds between probes |
| `LOSS_HOLD` | `5` | Consecutive failed probes before declaring the link down |
| `EXIT_AFTER_LOSS` | `0` | Seconds of continuous loss before exiting; 0 runs until Ctrl-C |
| `PING_TIMEOUT` | `1` | Per-probe, keep below `SAMPLE_INTERVAL` |
| `BW_MHZ`, `HEIGHT_M` | unset | Recorded verbatim |
| `OUT` / `LOGDIR` | `walktest.csv` / `rangetest-logs/` | |

Use `halow-rangetest.sh` for a careful measurement at a surveyed distance, and
this for finding the cliff edge. It trades precision for a continuous trace.

**Ping decides whether the link is alive, not `iw`.** A station lingers in
`station dump` for some time after it stops being reachable, so RSSI alone
would report a healthy link well past the actual cutoff. `LOSS_HOLD` adds
hysteresis: a single dropped ping at range is a fade, several in a row is a
cutoff. The script keeps running after loss and logs a `REGAINED` event if the
walker comes back, which is what you want when probing the boundary.

Nothing on the node knows how far away the walker is. Type a note and press
Enter at any point -- `200 m`, `past the treeline` -- and it lands on the next
row; otherwise correlate `elapsed_s` against a GPS track afterwards.

The number to take away is **weakest working RSSI**, reported in the summary.
That is the practical sensitivity floor at that bandwidth, and the figure the
whole range budget rests on. Budget 15-20 dB above it for a link you intend to
rely on, then repeat per bandwidth -- which means walking back, since both ends
must be reconfigured together.

### Installing `batman-adv`

Not packaged for noble -- `batman-adv-dkms` has no candidate,
and upstream ships a `Makefile` but no `dkms.conf` (Debian's packaging adds that).
`batctl` is in universe and pairs with any nearby module version:

```sh
sudo apt install batctl
```

The module is packaged in `batman/`, mirroring how `morse/` handles the driver:

```sh
git submodule update --init batman/batman-adv
./batman/install.sh
```

Uninstall with `./batman/install.sh --uninstall`.

Upstream states it "compiles against and should work with Linux 5.10 - 7.2",
so 6.8-tegra is in range.
The out-of-tree build is driven entirely by `KERNELPATH` (`README.external.rst`);
there is no configure step.

Upstream ships a `Makefile` but **no** `dkms.conf` -- Debian's packaging supplies one,
which is why there is no `batman-adv-dkms` in noble to install instead.
`batman/dkms.conf` is that missing file.
Like the driver installer,
`install.sh` stages a copy into `/usr/src` rather than pointing DKMS at the checkout,
because kernel-upgrade rebuilds run long afterwards
and must not depend on the working tree still existing
or still being on the same commit.

`PACKAGE_VERSION` in `batman/dkms.conf` tracks the submodule's pinned tag.
Bump both together -- DKMS keys its `/usr/src` tree on the name/version pair,
so a mismatch leaves stale sources installed under the old version.

Sources come from [open-mesh][om]; the submodule points at the
[GitHub mirror][ghm].

[om]: https://downloads.open-mesh.org/batman/releases/
[ghm]: https://github.com/open-mesh-mirror/batman-adv

### Order of Work

1. Two Jetsons, open IBSS, ping.
   This is the go/no-go for the whole approach.
2. Same two with `up-rsn` and a long random PSK.
3. `batman-adv` on top, then scale to four.
4. Convert the travel router to IBSS and add gateway mode -- see
   [openwrt_setup.md](openwrt_setup.md).
5. Decide bandwidth by measurement against the 750 m hop target -- see
   [Range and bandwidth](#range-and-bandwidth).
6. WireGuard over `bat0`.

On the Jetsons the `batman-adv` module has to be built -- see
[Installing batman-adv](#installing-batman-adv).
OpenWrt has both the module and `batctl` as packages, so the router needs none of that.

### Range and Bandwidth

Target coverage is a 1.5 km diameter area,
which the four nodes should span in hops of roughly 750 m.

Link budget for a 750 m hop at 915 MHz, assuming ~20 dBm TX
(what the Gateworks wiki reports for `txpower`) and ~2 dBi antennas each end:

| Condition | Path loss | RX power | Margin over 1 MHz sensitivity (~-105 dBm) |
| --- | --- | --- | --- |
| Free space, clear LOS (n=2) | ~89 dB | ~-65 dBm | ~40 dB |
| Antennas near ground, partial obstruction (n=3.5) | ~132 dB | ~-108 dBm | none -- below sensitivity |

So 750 m is either trivial or impossible depending on geometry,
and the configuration is what buys margin when geometry is poor.
Three consequences:

- **Antenna height dominates everything else.**
  The first Fresnel zone at 750 m / 915 MHz has a ~7 m radius at midpoint.
  Getting antennas to 3-5 m is worth more than any parameter in this repo.
- **Run 1 MHz, 2 MHz at the widest.** 8 MHz costs ~9 dB of sensitivity versus
  1 MHz for throughput this deployment does not need -- 1 MHz still gives
  ~4 Mbps at the top MCS.
- **The relay may not be where you need it.**
  Two 750 m hops assume a node near the midpoint.
  With four mobile nodes there will be moments when three cluster at one end
  and the fourth is at the far edge, needing the full 1.5 km as a single hop.
  Plausible at 1 MHz with height;
  not at 8 MHz. batman-adv handles the partition and rejoin cleanly,
  but cannot invent a relay that is not there.

**Do not bench-test these radios on the same desk.**
At 1 m the received level is about -8 dBm by the same arithmetic,
and a measured -12 dBm matches that closely.
Most 802.11 receivers start compressing around -20 dBm,
so at that range the front end is saturated: peering succeeds
(management frames use the most robust rate)
while every data frame fails,
which reads as a broken driver rather than as too much signal.
Reaching a healthy -50 dBm needs roughly 38 dB more loss -- about 80 m in free space.
Use 30 dB inline attenuators, or put the nodes in different rooms.
Target -40 to -60 dBm for functional testing,
and treat any RSSI taken at short range as meaningless for range planning.

Measure rather than trust the arithmetic. `halow-rangetest.sh` does the
collecting -- see [below](#halow-rangetestsh). Walk two nodes out, run it at
each position and bandwidth, and push outward until the 1 MHz link fails: that
distance is the real per-hop budget the 1.5 km topology rests on.

That yields the real path-loss exponent for the terrain,
which is the number that actually decides this --
and it differs enormously between open field, scrub and built-up ground,
so measure at the deployment site.
Budget 15-20 dB of fade margin for a link you intend to rely on.
Links that measure as barely working on a calm day fail on a wet one.

### The 802.11S Fallback

Only relevant if the IBSS gate fails.
Researched 2026-08-03; no code here depends on it.

**There is no prebuilt Tegra kernel with mesh support.**
An [NVIDIA forum thread][nv-mesh] reports exactly this problem on 6.8.12-1021-tegra --
our kernel -- with no `mesh point` iftype despite compatible hardware.
NVIDIA staff engaged but never said whether it is deliberate, whether it will change,
or how to work around it.
No resolution.
[OE4T/meta-tegra][oe4t] can flip the option via `scripts/patch_defconfig.sh`,
but that is still a kernel you build yourself.

That thread's author independently landed on "IBSS plus batman-adv and adding WireGuard
for security" -- the same stack as this repo.
Encouraging, but it is a stated plan in a forum post, not a report of success,
so it is not evidence that S1G IBSS works.
Only our own gate test settles that.

**Rebuild only the module, not the kernel.**
A [second thread][nv-boot] records boot loops
and NVMe rootfs mount failure needing a full reflash after enabling mesh.
The root cause is instructive: that user set `CONFIG_MAC80211=y`,
moving mac80211 from module to built-in,
which changes the kernel ABI and requires rebuilding every module
and updating the initrd with the out-of-tree modules.
Skipping that is what broke the boot,
because the PCIe wireless driver is read from initrd.

Our kernel already has `CONFIG_MAC80211=m`,
and `CONFIG_MAC80211_MESH` is a bool *inside* that module.
So the safe route is to leave `CONFIG_MAC80211=m` alone, flip only the mesh bool,
and rebuild `mac80211.ko` by itself -- no ABI change, no initrd surgery,
no reflash risk.
Drop the one `.ko` into `/lib/modules/$(uname -r)/updates/`
and rebuild `morse.ko` against it.
Set `CONFIG_LOCALVERSION` to keep the variant distinguishable.

This needs full L4T kernel source matching the running kernel;
the headers package does not carry `net/mac80211/*.c`.
It would then want wrapping in DKMS,
since it has to be applied to four Jetsons and survive kernel upgrades.

[nv-mesh]: https://forums.developer.nvidia.com/t/jetpack-7-2-kernel-6-8-no-802-11s-support-mesh-point-missing-despite-compatible-wifi-hardware/372457
[nv-boot]: https://forums.developer.nvidia.com/t/jetson-orin-nano-fails-to-boot-from-nvme-after-enabling-mac80211-mesh-batman-adv-built-using-oe4t-builder/338031
[oe4t]: https://github.com/OE4T/meta-tegra

### A Note on Security

RSN-IBSS is meaningfully weaker than the WPA3/SAE that 802.11s would give:
the PMK is `PBKDF2(passphrase, SSID, 4096)`,
so a captured handshake can be attacked offline indefinitely;
there is no forward secrecy; and every node can derive every other node's keys.
Management frames are unprotected, so spoofed deauths are a plausible denial of service.

Mitigations: a long random PSK
(25+ chars)
puts offline attack out of practical reach,
and WireGuard over `bat0` provides the real confidentiality
and integrity -- including across the router-to-Starlink hop,
which no link-layer crypto would cover.
Treat the link-layer crypto as hygiene and WireGuard as the actual security boundary.
Worth weighing that HaLow's kilometre-scale range is also the radius from
which someone can capture handshakes unseen.

## Layout

| Path | What |
| --- | --- |
| `halow-ibss.sh` | IBSS bring-up/test harness for the multi-hop work |
| `node-id.sh` | Shared interface detection and identity resolution; sourced, not run |
| `bat-hosts` | MAC to name, installed to `/etc/bat-hosts` |
| `hosts` | Name to `bat0` address, merged into `/etc/hosts` |
| `10-halow.link` | Renames the radio to `halow0`; install to `/etc/systemd/network/` |
| `halow-batman.sh` | `batman-adv` routing layer over the IBSS interface |
| `halow-rangetest.sh` | Field link-quality measurement, appends to `rangetest.csv` |
| `halow-walktest.sh` | Continuous trace while a node walks away; records the cutoff |
| `openwrt_setup.md` | Travel router as batman-adv gateway |
| `morse/morse_micro_install.sh` | Driver stack installer |
| `morse/dkms.conf` | Driver build config; staged into `/usr/src/morse-2.0.0` |
| `morse/install-firmware.sh` | DKMS `POST_INSTALL` hook, installs firmware |
| `morse/patches/` | Fixups applied to `morse_driver` by DKMS at build time |
| `morse/morse_driver/`, `morse/morse-firmware/`, `morse/hostap/`, `morse/morse_cli/` | Vendor submodules, unmodified |
| `batman/install.sh` | `batman-adv` module installer |
| `batman/dkms.conf` | Module build config; staged into `/usr/src/batman-adv-2026.2` |
| `batman/batman-adv/` | Upstream submodule, unmodified |

Openssl, libnl and libusb come from the distro; nothing is built out of tree.
