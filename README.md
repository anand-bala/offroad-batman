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

The repo holds two independently installable packages -- `morse/` for the
driver stack and `batman/` for the mesh routing module -- each with its own
`dkms.conf`, plus the bring-up scripts at the root. Neither install depends on
the other; a node that only needs the radio never has to build `batman-adv`.

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

### `halow-batman.sh`

Layers `batman-adv` over an IBSS interface. Run `halow-ibss.sh up` first; this
assumes `wlan0` is already in IBSS mode with a peer. Same shape -- a bring-up
harness, nothing persists across a reboot.

```sh
sudo BAT_IP=192.168.60.1/24 ./halow-batman.sh up
sudo ./halow-batman.sh status
sudo ./halow-batman.sh down
```

| Variable | Default | Notes |
| --- | --- | --- |
| `IFACE` / `BATIF` | `wlan0` / `bat0` | |
| `BAT_IP` | `192.168.60.1/24` | Unique per node; replaces the address on `wlan0` |
| `GW_MODE` | `off` | `server` on the uplink node, `client` elsewhere |
| `ROUTING_ALGO` | `BATMAN_IV` | Must be set before the mesh interface exists |
| `HARD_MTU` | unset | e.g. `1532`, to keep `bat0` at a full 1500 |

**The script flushes the IP off `wlan0`.** This is the behaviour most likely to
surprise: `halow-ibss.sh` puts `NODE_IP` there, but once `batman-adv` owns the
interface it must carry no address of its own or traffic takes the direct path
and silently bypasses mesh routing. Addressing moves to `bat0`, on a separate
subnet so it is obvious which layer is under test. `down` tears down only the
routing layer and leaves the IBSS up, so the transport can be retested alone.

`BATMAN_IV` is the default deliberately. `BATMAN_V` selects routes by estimated
throughput, which depends on the driver reporting sane rate information --
not an assumption worth making on an S1G driver this new.

`batman-adv` adds ~28 bytes of header, so `bat0` comes up around 1472 unless
the hard interface goes to 1532. Whether the Morse driver accepts an oversized
MTU is untested, hence opt-in via `HARD_MTU`.

Note `batman-adv` will happily form a mesh of one that looks entirely healthy
and forwards nothing, so the script warns when the IBSS has no peers. The real
check is `batctl meshif bat0 originators` listing the other nodes.

### Installing `batman-adv`

Not packaged for noble -- `batman-adv-dkms` has no candidate, and upstream
ships a `Makefile` but no `dkms.conf` (Debian's packaging adds that). `batctl`
is in universe and pairs with any nearby module version:

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
so 6.8-tegra is in range. The out-of-tree build is driven entirely by
`KERNELPATH` (`README.external.rst`); there is no configure step.

Upstream ships a `Makefile` but **no** `dkms.conf` -- Debian's packaging
supplies one, which is why there is no `batman-adv-dkms` in noble to install
instead. `batman/dkms.conf` is that missing file. Like the driver installer,
`install.sh` stages a copy into `/usr/src` rather than pointing DKMS at the
checkout, because kernel-upgrade rebuilds run long afterwards and must not
depend on the working tree still existing or still being on the same commit.

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
[Installing batman-adv](#installing-batman-adv). OpenWrt has both the module
and `batctl` as packages, so the router needs none of that.

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

**Do not bench-test these radios on the same desk.** At 1 m the received level
is about -8 dBm by the same arithmetic, and a measured -12 dBm matches that
closely. Most 802.11 receivers start compressing around -20 dBm, so at that
range the front end is saturated: peering succeeds (management frames use the
most robust rate) while every data frame fails, which reads as a broken driver
rather than as too much signal. Reaching a healthy -50 dBm needs roughly 38 dB
more loss -- about 80 m in free space. Use 30 dB inline attenuators, or put the
nodes in different rooms. Target -40 to -60 dBm for functional testing, and
treat any RSSI taken at short range as meaningless for range planning.

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

### The 802.11s Fallback

Only relevant if the IBSS gate fails. Researched 2026-08-03; no code here
depends on it.

**There is no prebuilt Tegra kernel with mesh support.** An
[NVIDIA forum thread][nv-mesh] reports exactly this problem on
6.8.12-1021-tegra -- our kernel -- with no `mesh point` iftype despite
compatible hardware. NVIDIA staff engaged but never said whether it is
deliberate, whether it will change, or how to work around it. No resolution.
[OE4T/meta-tegra][oe4t] can flip the option via `scripts/patch_defconfig.sh`,
but that is still a kernel you build yourself.

That thread's author independently landed on "IBSS plus batman-adv and adding
WireGuard for security" -- the same stack as this repo. Encouraging, but it is
a stated plan in a forum post, not a report of success, so it is not evidence
that S1G IBSS works. Only our own gate test settles that.

**Rebuild only the module, not the kernel.** A [second thread][nv-boot]
records boot loops and NVMe rootfs mount failure needing a full reflash after
enabling mesh. The root cause is instructive: that user set
`CONFIG_MAC80211=y`, moving mac80211 from module to built-in, which changes the
kernel ABI and requires rebuilding every module and updating the initrd with
the out-of-tree modules. Skipping that is what broke the boot, because the PCIe
wireless driver is read from initrd.

Our kernel already has `CONFIG_MAC80211=m`, and `CONFIG_MAC80211_MESH` is a
bool *inside* that module. So the safe route is to leave `CONFIG_MAC80211=m`
alone, flip only the mesh bool, and rebuild `mac80211.ko` by itself -- no ABI
change, no initrd surgery, no reflash risk. Drop the one `.ko` into
`/lib/modules/$(uname -r)/updates/` and rebuild `morse.ko` against it. Set
`CONFIG_LOCALVERSION` to keep the variant distinguishable.

This needs full L4T kernel source matching the running kernel; the headers
package does not carry `net/mac80211/*.c`. It would then want wrapping in DKMS,
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
| `halow-batman.sh` | `batman-adv` routing layer over the IBSS interface |
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
