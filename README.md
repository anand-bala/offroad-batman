# Na Na Na Na Na Na Na Na Offroad B.A.T.M.A.N

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

If the mesh is down, restarting the supplicant is the whole recovery:

```sh
sudo systemctl restart halow0-ibss.service   # pulls halow0-attach with it
```

Before doing that, capture the boot state -- a restart destroys the evidence:

```sh
systemctl status halow0-ibss halow0-attach
journalctl -b -u halow0-ibss -u halow0-attach --no-pager
iw reg get; rfkill list      # domain "00", or a soft block
ip -d link show halow0       # master bat0? type ibss?
```

Needing to restart `halow0-attach` *separately* now means something is wrong
beyond the boot races described under Design Notes.

### The Mesh Is Dual Stack

`bat0` carries two static addresses, and which one you use decides what you are
actually testing:

| Family | Address | What it is for |
| --- | --- | --- |
| IPv6 ULA | `fdc7:37f3:e24a:0::/64`, EUI-64 per node | the mesh's own addressing; works with no router present |
| IPv4 | `192.168.12.0/24`, roster position per node | the way out, and the way in from a laptop |

**The mesh was IPv6-only until the uplink was measured.** That design assumed
the router had a v6 uplink to masquerade onto. It does not -- `eth0` there takes
a v4 DHCP lease and a link-local, with no global v6 and no v6 default route, so
an IPv6-only mesh has no path off the router whatever batman and the firewall
do. The v6 half is still the mesh's own layer and still what `.mesh` names
resolve to; v4 is what reaches the internet and what a laptop on the router's
WiFi can talk to.

The v4 addresses land on the router's LAN because that is where `bat0` already
is: the router bridges it into `br-ahwlan` alongside `eth1` and both SoC APs,
so every node is L2-adjacent to that `/24`. Host octets come from roster
position (`node_mesh_addr4`), starting at `.11` and bounded below `.100` so they
cannot collide with the dnsmasq pool that serves the laptops.

Test the uplink over v4, which is the family that has one:

```sh
ping -I bat0 1.1.1.1        # Cloudflare
ping -I bat0 192.168.12.1   # just the router, if that fails
```

Use the `-I bat0` form whenever the node also has Ethernet or WiFi up.
Without it a working reply may have gone out the other interface entirely,
which tests nothing about the mesh.

`ping6 2606:4700:4700::1111` still fails from a Jetson, and is **not** a broken
mesh -- there is no v6 uplink for it to cross. `ping6 <node>.mesh` between
Jetsons is the v6 test that should pass.

If the uplink test fails, work down the layers rather than guessing:

```sh
ip -4 route show default    # expect: default via 192.168.12.1 dev bat0
ping -I bat0 192.168.12.1   # the router itself, over the mesh
batctl o                    # expect the router as an originator
batctl gwl                  # expect the router listed, with a => on the selected one
resolvectl query one.one.one.one # DNS, once the above pass
```

A default route with an empty `batctl o` means `bat0` on the router has lost its
hard interface -- `batctl meshif bat0 interface add wlan0` there, and see
[docs/OPENWRT.md](docs/OPENWRT.md) for why `rc.local` loses that race.
The router answering while the internet does not puts the fault on its WAN
side: the `ahwlan` firewall zone or `masq`.

### Getting a Laptop to a Node

A laptop on the router's `haylo-wifi` (2.4 GHz) or `heylo-wifi` (5 GHz) gets a
dnsmasq lease on `192.168.12.0/24` -- the same `/24` the nodes are on, one
bridge away. So SSH needs no jump host and no route:

```sh
ssh <node>@192.168.12.13    # ragnarhorn, per the roster
ssh <node>@<node>.local     # or by name, mDNS over the same link
```

This works because the router bridges `bat0` into `br-ahwlan`. The cost of that
bridge is real and is paid on the radio: every LAN broadcast and multicast frame
-- ARP, mDNS, SSDP -- floods into a 1 MHz channel carrying a few hundred kbit/s.
Measure it (`batman_oracle.sh tp`) before assuming it is free.

### DNS on the Bench: Mesh Down, Ethernet Up

`bat0` claims the catch-all DNS routing domain (`Domains=~.`),
which on its own sends **every** lookup to the mesh resolvers --
even with the mesh down and a healthy Ethernet uplink right there.
The symptom is total: `getent hosts google.com` fails with
`No route to host` while `ping 8.8.8.8` over Ethernet works fine,
which reads exactly like a dead uplink and is not one.

The installer therefore stamps the same `~.` routing domain onto every
NetworkManager Ethernet profile present at install time.
`resolved` then queries both scopes and the first good answer wins:
Ethernet answers on the bench, the mesh answers in the field,
and with both up the race is harmless.

Profiles minted *after* the install are covered too:
NetworkManager creates a fresh `Wired connection N` for every new
dongle (a swapped adapter reintroduced the whole failure once),
so a dispatcher hook
(`etc/NetworkManager/dispatcher.d/90-dns-mesh-coexist`)
stamps each Ethernet profile at the moment it activates.
`journalctl -t dns-mesh-coexist` shows it firing.

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

## Diagnostics and Field Measurement

`batman_oracle.sh` is the one diagnostics tool.
It replaces `halow-measure.sh` and the `status` subcommand of `halow-batman.sh`;
the old IBSS/batman bring-up harnesses are gone,
superseded by `install_network_stack.sh` and the systemd units.

```sh
./batman_oracle.sh status                    # whole-fleet health
NODE=olo PEER=wazza ... ./batman_oracle.sh at 750 "clear LOS, dry"
NODE=olo PEER=wazza ... ./batman_oracle.sh tp 750     # throughput, both directions
NODE=olo PEER=wazza ... ./batman_oracle.sh walk       # trace until the link dies
NODE=olo ./batman_oracle.sh soak                      # unattended logging
./batman_oracle.sh hosts                              # roster as /etc/hosts entries
```

**It is a remote control head, not a node.**
Run it from a laptop on the router's Ethernet:
every reading, including the ping, is taken *on* a node over ssh.
A ping issued by the laptop would cross Ethernet and the router
before touching a radio and would measure nothing useful.
Run on a Jetson it is the same code path with the ssh hop elided.

`NODE` is the node to measure from, `PEER` the node to measure to,
both roster names from `etc/bat-hosts`.
`BW_MHZ` and `HEIGHT_M` are recorded verbatim, not measured --
record height every time,
it dominates path loss and a row without it cannot be compared.

Use `at` for a number going into a range budget and `walk` for finding the cliff
edge. `at` and `tp` are split on the passive/active line and write to separate
CSVs: at 1 MHz a throughput run does not perturb the link, it saturates it.
The number to take away from a walk is **weakest working RSSI**:
that is the practical sensitivity floor, and the whole range budget rests on it.
Budget 15-20 dB above it for a link you intend to rely on.

Bandwidth changes need both ends reconfigured,
so do every bandwidth at one position before moving.

Clock sync is a hard prerequisite for `soak` --
cross-node timestamps are only joinable if the clocks agree,
and these Jetsons have no RTC.
See [docs/MONITORING.md](docs/MONITORING.md) for that, the laptop setup,
the output schemas, and how to read the results.

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

**Boot ordering is gated, not merely ordered.**
Nodes came up after a field reboot with both units green and no mesh,
fixed only by restarting them by hand.
Ordering alone could not prevent that, because the signals systemd had were lies.
`iw reg set` returns once the request is queued,
so the supplicant could enumerate channels while the domain was still world-roaming
and find the S1G channel disallowed --
it does not exit over that, it just never joins,
so `Restart=on-failure` never fires.
And `halow0-ibss` is `Type=simple`,
so it counted as started the instant `wpa_supplicant_s1g` forked,
long before it had taken the link down, set type IBSS and joined;
`halow0-attach` enslaved to `bat0` inside that window
and got a slave that never carried anything.
Both units now gate on the real condition via
`usr/local/lib/halow/halow-wait` (`regdom`, `joined`),
which fails on timeout rather than falling through --
with `StartLimitIntervalSec=0` on both,
that is a visible retry loop in the journal, not a unit latched into
a state needing `systemctl reset-failed` on a node nobody can reach.
`halow0-attach` also gained `Restart=on-failure`,
since a `Type=oneshot` that lost a race stayed lost until the next reboot.

**`halow0-attach` is `PartOf=halow0-ibss`.**
`Requires=` forwards an explicit stop but *not* a restart,
so restarting the supplicant used to run attach's `ExecStop` (`nomaster`)
and leave it stopped --
an already-satisfied `WantedBy=` is not pulled again.
Restarting `halow0-ibss` therefore detached the radio from `bat0` silently.
This also means "I had to restart both" says nothing about a root cause:
it was forced by the wiring, whatever the underlying fault.

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
   Done: the router meshes, forwards `mesh` -> `wan`, and masquerades v6.
   The Jetson half is the static `Gateway=` in `25-bat0.network`; batman
   gateway mode does not create a route on a mesh with no DHCP.
5. Decide bandwidth by measurement against the 750 m hop target.
6. WireGuard over `bat0`.

See also [docs/HTTP_COMMS.md](docs/HTTP_COMMS.md)
for application-level comms over the mesh.
