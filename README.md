# Na Na Na Na Na Na Na Na Offroad B.a.t.m.a.n

A HaLow (802.11ah) mesh for three Jetson nodes plus an OpenWrt travel router
as the gateway.
IBSS at layer 2, `batman-adv` routing on top,
dual stack over an IPv6 ULA and the router's IPv4 LAN.

Two scripts do the whole install.
Both run on the node, with the radio plugged in; nothing cross-compiles.

| Document | Covers |
| --- | --- |
| this file | the Jetson side: install, addressing, naming, design rationale |
| [docs/OPENWRT.md](docs/OPENWRT.md) | the router: bridge, firewall, uplink, radio parameters |
| [docs/MONITORING.md](docs/MONITORING.md) | `batman_oracle.sh`, measurement method, output schemas |
| [docs/HTTP_COMMS.md](docs/HTTP_COMMS.md) | writing services that talk between nodes |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | symptoms, and what each has turned out to be |

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
Nothing is edited per node:
each one works out its own name and address from its radio MAC (see
[Fleet configuration](#fleet-configuration)).

`build_dependencies.sh` builds `morse.ko` + `dot11ah.ko` and `batman-adv` via DKMS,
so they survive kernel upgrades, and installs `wpa_supplicant_s1g`,
`hostapd_s1g` and `morse_cli` into `/usr/local/sbin` (`BINDIR` to override).
It takes `--no-morse`, `--no-batman` and `--uninstall`.

Both reboots are needed.
The first loads the freshly built modules and brings up the radio,
which the network stack install has to be able to find.
The second applies the rename to `halow0`, the IBSS bring-up and the enslaving,
all of which are disruptive to a live link,
so a reboot is the safe path on a remote node.

### Before You Start

The card is driven over USB, which is what the GW16167 M.2 2230 E-key module uses.
Check the link before blaming the driver:

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

The station dump and `batctl o` are the checks that mean something.
IBSS forms a cell of one and reports success with no peer,
and `batman-adv` will form a mesh of one that forwards nothing,
so anything short of seeing the other nodes listed proves very little.

If any of it fails, see [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## Addressing

`bat0` carries two static addresses.

| Family | Address | Role |
| --- | --- | --- |
| IPv6 ULA | `fdc7:37f3:e24a:0::/64`, EUI-64 from the radio MAC | the mesh's own layer; works with no router present |
| IPv4 | `192.168.12.0/24`, host octet from roster position | the way out to the internet, and the way in from a laptop |

Both are stamped into `etc/systemd/network/25-bat0.network` by
`install_network_stack.sh`.

The v4 addresses sit on the router's LAN because that is where `bat0` already is:
the router bridges it into `br-ahwlan` alongside `eth1` and both SoC APs,
so every node is L2-adjacent to that `/24`.
Host octets come from roster position (`node_mesh_addr4`),
starting at `.11` and bounded below `.100` so they cannot collide with the dnsmasq pool
that serves the laptops.

IPv4 is what reaches the internet, because the router's uplink has no IPv6:
`eth0` there takes a v4 DHCP lease and a link-local,
with no global v6 and no v6 default route.
The v6 half is the mesh's own layer and is what `.mesh` and `.local` names resolve to.

Test the uplink over v4, which is the family that has one:

```sh
ping -I bat0 1.1.1.1      # Cloudflare
ping -I bat0 192.168.12.1 # just the router, if that fails
```

Use the `-I bat0` form whenever the node also has Ethernet or WiFi up.
Without it a working reply may have gone out the other interface entirely,
which tests nothing about the mesh.

### Getting a Laptop to a Node

A laptop on the router's `haylo-wifi` (2.4 GHz) or `heylo-wifi`
(5 GHz)
gets a dnsmasq lease on `192.168.12.0/24`, the same `/24` the nodes are on,
one bridge away.
SSH therefore needs no jump host and no route:

```sh
ssh robot@192.168.12.13    # ragnarhorn, per the roster
ssh robot@ragnarhorn.local # or by name, mDNS over the same link
```

The bridge costs airtime.
Every LAN broadcast and multicast frame floods into a 1 MHz channel carrying a few
hundred kbit/s, so keep clients off the APs during a measurement run.

## Fleet Configuration

The one file to edit is `etc/bat-hosts`: one line per node, radio MAC to name.
Hostname, the `<name>.mesh` address,
the IPv4 host octet and the static entries merged into `/etc/hosts` all follow from it.
Add a node by appending a line, then rerun `./install_network_stack.sh` everywhere.

Append, do not insert.
`node_mesh_addr4` derives the IPv4 host octet from a node's line position in the roster,
so putting a new entry anywhere but the end renumbers every node below it,
and they will not know until they are reinstalled.
The IPv6 half is derived from the MAC and is unaffected.

IPv6 addresses are a shared `/64` prefix plus an EUI-64 suffix derived from each radio's
MAC.
The prefix is fleet-wide (`ULA_PREFIX` in `install_network_stack.sh`);
regenerating it per node silently partitions the mesh.

Each node answers to two names: `<name>.mesh`
(static, from `bat-hosts`) and `<name>.local` (mDNS via systemd-resolved).
Avahi is masked during install so the two mDNS stacks cannot collide.

The installer also stamps the `~.` DNS routing domain onto every NetworkManager Ethernet
profile, and `etc/NetworkManager/dispatcher.d/90-dns-mesh-coexist` does the same for
profiles created later, such as the fresh `Wired connection N` a swapped dongle mints.
That keeps Ethernet contributing a DNS scope of its own,
so a bench uplink answers lookups whatever else is configured.
`journalctl -t dns-mesh-coexist` shows the hook firing.

`NODE_NAME`, `ULA_PREFIX`, `GATEWAY_NAME`, `MESH_V4_SUBNET`,
`MESH_V4_BASE` and `MESH_V4_GATEWAY` can all be exported to override the derived values.
Setting `GATEWAY_NAME` empty installs no default route at all,
which is what you want on an isolated bench pair.

Three open decisions live in `etc/wpa_supplicant/wpa_supplicant-halow0.conf`: open IBSS
(`key_mgmt=NONE`, the default)
versus the commented RSN block plus a PSK;
whether the driver accepts `channel`/`op_class` for IBSS or needs `frequency=` instead;
and `s1g_prim_1mhz_chan_index`,
which must be `0` at 1 MHz and has to change if the fleet ever widens
(see the channel table in [docs/OPENWRT.md](docs/OPENWRT.md)).

### The Radio Is `halow0`

The card is USB, so predictable naming would give it a MAC-derived name
that differs on every node.
`10-halow.link` renames it by driver match, so one identical file works fleet-wide.

The name is deliberately outside the kernel's own `wlanN` namespace.
Renaming into that namespace fails *intermittently*,
when the kernel hands the name to another device first,
which is a poor failure mode on a node you cannot reach.
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

This reaches that node.
It says nothing about the state of the mesh.

## Diagnostics and Field Measurement

`batman_oracle.sh` is the diagnostics tool.

```sh
./batman_oracle.sh status # whole-fleet health
NODE=olo PEER=wazza ... ./batman_oracle.sh at 750 "clear LOS, dry"
NODE=olo PEER=wazza ... ./batman_oracle.sh tp 750 # throughput, both directions
NODE=olo PEER=wazza ... ./batman_oracle.sh walk   # trace until the link dies
NODE=olo ./batman_oracle.sh soak                  # unattended logging
./batman_oracle.sh hosts                          # roster as /etc/hosts entries
```

It runs on a machine outside the mesh and drives the nodes over ssh.
Run it from a laptop on the router's Ethernet or WiFi.
Every reading, including the ping, is taken *on* a node.
A ping issued by the laptop would cross Ethernet and the router before touching a radio
and would measure nothing useful.
Run on a Jetson it is the same code path with the ssh hop elided.

### The Laptop Needs an Address on the Mesh Prefix

The laptop reaches the nodes over IPv4 for ordinary work
(`ssh robot@192.168.12.13`), but the oracle does not use those addresses.
`node_target` hands ssh the derived IPv6 ULA,
because that needs no resolver on either end and the laptop has never run the installer.

So the laptop needs an address on the fleet's `/64`
or every oracle command fails at the ssh hop.
Nothing else is required: the nodes are already on-link across the router's bridge,
and neighbour discovery does the rest.

```sh
sudo ip addr add fdc7:37f3:e24a::99/64 dev <laptop-iface>
ping6 -c3 fdc7:37f3:e24a:0:0ebf:74ff:fe00:5e19   # ragnarhorn, to confirm
SSH_USER=<user> ./batman_oracle.sh status
```

Pick a host suffix that cannot collide with a node's EUI-64.
`::99` is fine; anything derived from a MAC is not.
Make it permanent once it works, or it is gone at the next reboot:

```sh
nmcli con mod fdc7:37f3:e24a::99/64 <profile >+ipv6.addresses
```

The oracle can also run on the router, which needs no address setup
(it holds the prefix already)
but does need `opkg update && opkg install bash`, and writes its CSVs to limited flash,
so point them at `/tmp` or a USB stick.
The ssh hop crosses the same HaLow link from either place,
so this is a convenience choice and not an accuracy one.

Either way, ssh must be non-interactive: the oracle runs `BatchMode=yes`,
so key auth has to already work.

```sh
./batman_oracle.sh hosts | sudo tee -a /etc/hosts # <name>.mesh entries
ssh-copy-id <user >@ragnarhorn.mesh               # once per node
```

`NODE` is the node to measure from, `PEER` the node to measure to,
both roster names from `etc/bat-hosts`.
`BW_MHZ` and `HEIGHT_M` are recorded verbatim; the tool takes your word for both.
Record height every time: it dominates path loss,
and a row without it cannot be compared.

Use `at` for a number going into a range budget and `walk` for finding the cliff edge.
`at` and `tp` are split on the passive/active line and write to separate CSVs,
because at 1 MHz a throughput run does not perturb the link, it saturates it.
The number to take away from a walk is the weakest working RSSI,
which is the practical sensitivity floor the range budget rests on.
Budget 15-20 dB above it for a link you intend to rely on.

Bandwidth changes need both ends reconfigured,
so do every bandwidth at one position before moving.

Clock sync is a hard prerequisite for `soak`,
since cross-node timestamps are only joinable if the clocks agree
and these Jetsons have no RTC.
See [docs/MONITORING.md](docs/MONITORING.md) for that, the laptop setup,
the output schemas, and how to read the results.

## Design Notes

Why the system is shaped the way it is.

### IBSS + `batman-adv`

`batman-adv` handles node churn better than HWMP,
and 802.11s is unavailable on these Jetsons in any case:
`CONFIG_MAC80211_MESH` is off in the L4T kernel,
so the driver compiles the mesh iftype out.
Getting it would mean rebuilding `mac80211` from kernel source
and the driver against that.

### Run 1 MHz, 2 MHz at the Widest

Target is a 1.5 km area in ~750 m hops.
At 915 MHz that hop is either trivial or impossible depending on geometry:
free space gives ~40 dB of margin,
antennas near the ground with partial obstruction gives none. 8 MHz costs ~9 dB of
sensitivity for throughput this deployment does not need.

Antenna height buys more than any parameter here.
The first Fresnel zone is ~7 m at midpoint, so get antennas to 3-5 m.

Bench-testing two of these radios on the same desk does not work;
the front end saturates.
See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

### Boot Is Gated on Real Conditions

`halow0-ibss` and `halow0-attach` both gate on `usr/local/lib/halow/halow-wait`
(`regdom`, `joined`) rather than on unit ordering.
Ordering alone is not enough here,
because the signals available to order against do not mean what they appear to:
`iw reg set` returns once the request is queued,
and a `Type=simple` supplicant counts as started the instant it forks.

`halow-wait` fails on timeout instead of falling through.
With `StartLimitIntervalSec=0` on both units,
that surfaces as a visible retry loop in the journal,
and nothing latches into a state needing `systemctl reset-failed` on a node nobody can
reach.
`halow0-attach` also carries `Restart=on-failure`,
since a `Type=oneshot` that loses a race would otherwise stay lost until reboot.

`halow0-attach` is `PartOf=halow0-ibss`,
so restarting the supplicant carries the attach with it.
`Requires=` would not: it forwards an explicit stop but not a restart.

### Security

RSN-IBSS is weaker than WPA3/SAE: offline-attackable handshake, no forward secrecy,
every node can derive every other node's keys, unprotected management frames.
Use a 25+ character random PSK,
and treat WireGuard over `bat0` as the actual security boundary.
It also covers the router-to-Starlink hop, which no link-layer crypto would.
HaLow's kilometre-scale range is also the radius from
which someone can capture handshakes unseen.

## Order of Work

1. Two Jetsons, open IBSS, ping `<a>.mesh` <-> `<b>.mesh` both ways.
   This is the go/no-go for the whole approach.
2. Same two with RSN-IBSS and a long random PSK.
3. `batman-adv` on top, then scale to the full roster.
4. Router as gateway; see [docs/OPENWRT.md](docs/OPENWRT.md).
   Done: it meshes and forwards `ahwlan` -> `wan` with IPv4 masquerading.
5. Decide bandwidth by measurement against the 750 m hop target.
6. WireGuard over `bat0`.
