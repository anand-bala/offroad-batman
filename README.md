# Na Na Na Na Na Na Na Na Offroad B.a.t.m.a.n

A HaLow (802.11ah) mesh for four Jetson nodes plus an OpenWrt travel router
as the gateway.
IBSS at layer 2, `batman-adv` routing on top, addressed over IPv6 ULA.

Two scripts do the whole install.
Both run **on the node**, with the radio plugged in; nothing cross-compiles.

## Setup

```sh
git clone --recurse-submodules <this repo>
cd offroad-batman

./build_dependencies.sh     # drivers, firmware, userspace tools
sudo reboot

./install_network_stack.sh  # systemd units, addressing, hostname
sudo reboot
```

Run the same two commands on every node.
Nothing is edited per node -- each one works out its own name
and address from its radio MAC (see
[Fleet configuration](#fleet-configuration)).

`build_dependencies.sh` builds `morse.ko` + `dot11ah.ko` and `batman-adv` via DKMS,
so they survive kernel upgrades, and installs `wpa_supplicant_s1g`,
`hostapd_s1g` and `morse_cli` into `/usr/local/sbin` (`BINDIR` to override).
It takes `--no-morse`, `--no-batman` and `--uninstall`.

The first reboot matters: the freshly built modules must be loaded and the radio present
before the network stack install can find it.
The second applies the rename to `halow0`,
the IBSS bring-up and the enslaving cleanly -- all disruptive to a live link,
so a reboot is the safe path on a remote node.

### Before You Start

The card is driven over USB, which is what the GW16167 M.2 2230 E-key module uses.
If the radio does not appear, check the link before blaming the driver:

```sh
lsusb -d 325b: # expect 325b:8100
```

Not every M.2 E-key slot wires up USB 2.0,
and the driver cannot see a card that is only on PCIe lanes.

### Verify (After the Second Reboot)

```bash
networkctl status bat0     # UP, has the ULA
iw dev halow0 info         # type IBSS
iw dev halow0 station dump # the peer's MAC must be listed
batctl n
batctl o                 # neighbours / originators
ping6 <othernode >.local # end to end
```

`iw dev halow0 link` is not enough -- IBSS forms a cell of one
and looks healthy with no peer.
Likewise `batman-adv` will form a mesh of one that forwards nothing,
so `batctl o` listing the other nodes is the real check.

## Fleet Configuration

The one file to edit is `etc/bat-hosts`: one line per node, radio MAC to name.
Everything else follows from it -- hostname, `<name>.mesh` address,
the static entries merged into `/etc/hosts`.
Adding a node is one line, then rerun `./install_network_stack.sh` everywhere.

Addresses are IPv6 ULA: a shared `/64` prefix plus an EUI-64 suffix derived from each
radio's MAC.
**The prefix is fleet-wide** -- `ULA_PREFIX` in `install_network_stack.sh`.
Regenerating it per node silently partitions the mesh.

Each node answers to two names: `<name>.mesh`
(static, from `bat-hosts`) and `<name>.local` (mDNS via systemd-resolved).
Avahi is masked during install so the two mDNS stacks cannot collide.

`NODE_NAME` and `ULA_PREFIX` can be exported to override the derived values.

Two open decisions live in `etc/wpa_supplicant/wpa_supplicant-halow0.conf`: open IBSS
(`key_mgmt=NONE`, the default)
versus the commented RSN block plus a PSK,
and whether the driver accepts `channel`/`op_class` for IBSS
or needs `frequency=` instead.

### The Radio Is `halow0`, Not `wlan0`

The card is USB, so predictable naming would give it a MAC-derived name
that differs on every node.
`10-halow.link` renames it by driver match, so one identical file works fleet-wide.

It is deliberately not `wlan0`:
renaming into the kernel's own namespace fails *intermittently* when the kernel hands
that name to another device first -- a poor failure mode on a node you cannot reach.
The cost is that by-hand `morse_cli` invocations need `-i halow0`.

## Getting into a Node

Bring-up destroys the radio link, so keep a path in that does not depend on the mesh.
A laptop on a direct Ethernet cable (auto-MDIX makes an ordinary cable fine):

```sh
sudo ip addr add 192.168.70.1/24 dev <laptop-eth>   # laptop
sudo ip addr add 192.168.70.2/24 dev eth0           # jetson
ssh <node>@192.168.70.2
```

`192.168.70.0/24` cannot collide with anything the mesh uses.
Zero-config fallbacks for when the static setup is itself the broken thing:

```sh
ssh <node>@<node>.local
ping6 -I <laptop-eth> ff02::1     # discover, then
ssh <node>@fe80::XXXX%<laptop-eth>
```

This reaches *that node*, not the mesh.

## Field Measurement

`halow-measure.sh` measures link quality, in two modes:

```sh
# one careful measurement at a surveyed distance
sudo PEER= BW_MHZ=1 HEIGHT_M=4 ./halow-measure.sh at 750 "clear LOS, dry" <node >.mesh

# continuous trace while the other node walks away; run on the STATIONARY node
sudo PEER= BW_MHZ=1 HEIGHT_M=4 OUT=walk-1mhz.csv ./halow-measure.sh walk <node >.mesh
```

`PEER` is required; `BW_MHZ` and `HEIGHT_M` are recorded verbatim,
not measured -- record height every time,
it dominates path loss and a row without it cannot be compared.
Raw output lands in `rangetest-logs/`.

Use `at` for a number going into a range budget and `walk` for finding the cliff edge.
The number to take away from a walk is **weakest working RSSI**:
that is the practical sensitivity floor, and the whole range budget rests on it.
Budget 15-20 dB above it for a link you intend to rely on.

Bandwidth changes need both ends reconfigured,
so do every bandwidth at one position before moving.

## Design Notes

**IBSS + `batman-adv`, not 802.11s.**
`batman-adv` handles node churn far better than HWMP,
and 802.11s is not available on these Jetsons anyway -- `CONFIG_MAC80211_MESH` is off in
the L4T kernel, so the driver compiles the mesh iftype out.
Getting it would mean rebuilding `mac80211` from kernel source
and the driver against that.

**Run 1 MHz, 2 MHz at the widest.**
Target is a 1.5 km area in ~750 m hops.
At 915 MHz that hop is either trivial or impossible depending on geometry:
free space gives ~40 dB of margin,
antennas near the ground with partial obstruction gives none. 8 MHz costs ~9 dB of
sensitivity for throughput this deployment does not need.
Antenna height buys more than any parameter here -- the first Fresnel zone is ~7 m at
midpoint, so get antennas to 3-5 m.

**Do not bench-test these radios on the same desk.**
At 1 m the received level is around -8 dBm and the front end saturates:
peering succeeds while every data frame fails,
which reads as a broken driver rather than as too much signal.
Target -40 to -60 dBm -- different rooms,
or 30 dB inline attenuators -- and treat any RSSI taken at short range as meaningless
for range planning.

**Security.**
RSN-IBSS is weaker than WPA3/SAE: offline-attackable handshake, no forward secrecy,
every node can derive every other node's keys, unprotected management frames.
Use a 25+ character random PSK,
and treat WireGuard over `bat0`
as the actual security boundary -- it also covers the router-to-Starlink hop,
which no link-layer crypto would.
HaLow's kilometre-scale range is also the radius from
which someone can capture handshakes unseen.

## Order of Work

1. Two Jetsons, open IBSS, ping `<a>.mesh` <-> `<b>.mesh` **both ways**.
   This is the go/no-go for the whole approach.
2. Same two with RSN-IBSS and a long random PSK.
3. `batman-adv` on top, then scale to four.
4. Convert the travel router to IBSS and add gateway mode -- see
   [docs/OPENWRT.md](docs/OPENWRT.md).
5. Decide bandwidth by measurement against the 750 m hop target.
6. WireGuard over `bat0`.

See also [docs/HTTP_COMMS.md](docs/HTTP_COMMS.md)
for application-level comms over the mesh.
