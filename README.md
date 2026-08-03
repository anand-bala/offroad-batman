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
./morse_micro_install.sh
```

Installs:

- `morse.ko` + `dot11ah.ko` via DKMS, so they rebuild on kernel upgrades
- firmware and BCFs into `/lib/firmware/morse`
- `hostapd_s1g`, `wpa_supplicant_s1g`, `morse_cli` and friends into `$BINDIR`

Environment overrides: `BINDIR` (default `/usr/local/sbin`) and `COUNTRY`
(default `US`, baked into both the module and `/etc/modprobe.d/morse.conf`).

Uninstall with `./morse_micro_install.sh --uninstall`.
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

Note that any `wpa_supplicant_s1g` built
before 2026-08-03 has no `CONFIG_MESH` regardless:
`write_hostap_config` took its option lists as space-joined scalars and iterated them
as arrays, so every `sed` missed and both daemons were built straight from `defconfig`.
Fixed now, but binaries predating the fix are missing all the `WPA_S_ENABLE` /
`HOSTAPD_ENABLE` options and need a rebuild.
`CONFIG_SAE` and `CONFIG_IBSS_RSN` are on in `defconfig` already,
so the IBSS path works on either build.

### `halow-ibss.sh`

Brings an interface up in IBSS mode for bring-up and testing.
Not a production service -- nothing persists across a reboot, by design.

```sh
sudo NODE_IP=192.168.50.1/24 DEBUG=1 ./halow-ibss.sh up # open IBSS
sudo NODE_IP=192.168.50.2/24 ./halow-ibss.sh up-rsn     # RSN-IBSS, needs PSK
sudo ./halow-ibss.sh status
sudo ./halow-ibss.sh down
```

Run identical parameters on every node; only `NODE_IP` differs.

| Variable | Default | Notes |
| --- | --- | --- |
| `IFACE` / `PHY` | `wlan0` / `phy0` | |
| `SSID` | `HaLow-IBSS` | Must match fleet-wide |
| `CHANNEL` / `OP_CLASS` | `33` / `68` (1 MHz @ 918.5 MHz) | Must match fleet-wide |
| `FREQ` | unset | Fallback: emits `frequency=` instead of `channel`/`op_class` |
| `NODE_IP` | `192.168.50.1/24` | Unique per node |
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

`batman-adv` is not packaged for noble
(`batman-adv-dkms` has no candidate),
so on the Jetsons it comes from the open-mesh release tarballs,
which ship a DKMS-ready tree.
`batctl` itself is in universe.
OpenWrt has both as packages.

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

Measure rather than trust the arithmetic.
Walk two nodes to 750 m and to 1.5 km at each bandwidth and record:

```sh
iw dev wlan0 station dump | grep -E 'signal|bitrate' # per-peer RSSI
batctl meshif bat0 originators                       # TQ, 0-255
morse_cli -i wlan0 stats
```

That yields the real path-loss exponent for the terrain,
which is the number that actually decides this --
and it differs enormously between open field, scrub and built-up ground,
so measure at the deployment site.
Budget 15-20 dB of fade margin for a link you intend to rely on.
Links that measure as barely working on a calm day fail on a wet one.

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
| `morse_micro_install.sh` | The only thing you need to run |
| `dkms.conf` | Driver build config; staged into `/usr/src/morse-2.0.0` |
| `install-firmware.sh` | DKMS `POST_INSTALL` hook, installs firmware |
| `halow-ibss.sh` | IBSS bring-up/test harness for the multi-hop work |
| `openwrt_setup.md` | Travel router as batman-adv gateway |
| `patches/` | Fixups applied to `morse_driver` by DKMS at build time |
| `morse_driver/`, `morse-firmware/`, `hostap/`, `morse_cli/` | Vendor submodules, unmodified |

Openssl, libnl and libusb come from the distro; nothing is built out of tree.
