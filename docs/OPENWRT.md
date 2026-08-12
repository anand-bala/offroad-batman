# Travel Router (OpenWrt) as Mesh Gateway

The router is from the **Morse Micro MM8108-EKH19 evaluation kit**: a GL.iNet GL-MT3000,
an MM8108 USB 2.0 adapter, an SMA HaLow antenna, and Morse's OpenWrt image
(23.05.5, Morse-2.9.3).
The adapter is USB and hot-pluggable.

The whole fleet is MM8108 -- Jetsons over a Gateworks M.2 module,
the router over this kit's USB adapter.
Same silicon, different host interface,
so the radio parameters here are the Jetsons' parameters verbatim.

It does three jobs:

1. **Gateway.**
   It holds the uplink, and every Jetson routes out through it.
2. **Bridge onto the LAN.**
   The mesh and the router's own WiFi are one layer 2 domain,
   so a laptop on the AP can reach a Jetson directly.
3. **Clock.**
   The Jetsons have no RTC and take their time from here.

> **This document describes a router that is built and working**,
> not a conversion to perform.
> It was a conversion guide once, written before the hardware existed,
> and much of what it predicted turned out wrong -- see
> [What Changed, and Why](#what-changed-and-why) for the corrections, which are the most
> useful part of it if you are holding an older copy.

Everything below is shell.
LuCI can express most of it and the earlier version of this document led with LuCI,
but the router is worked on over SSH in practice,
and the LuCI paths went stale faster than the commands did.

```sh
ssh root@192.168.12.1
```

## The Map

This is the whole of it.
Read this section and the rest is detail.

```text
                 eth0 ---------------------------------> uplink (DHCP v4)
                  |                                       192.168.1.0/24
                  |  masq, mtu_fix                        default via .1
                  |
             [ fw4: wan zone ]
                  ^
                  | forwarding: ahwlan -> wan
                  |
             [ fw4: ahwlan zone ]  input/output/forward ACCEPT
                  |
              br-ahwlan  192.168.12.1/24, dnsmasq .100-.249
                  |
      +-----------+-----------+-----------+
      |           |           |           |
    eth1      phy1-ap0    phy2-ap0      bat0
   (LAN)      2.4 GHz      5 GHz          |
              haylo-       heylo-      batman-adv
              wifi         wifi           |
                                        wlan0   IBSS, S1G ch 33, 1 MHz
                                          |     SSID HaLow-Mesh
                                          v
                                     the Jetsons
```

| Thing | Value |
| --- | --- |
| HaLow netdev | `wlan0` (phy#0, the `morse` driver) |
| HaLow MAC | `0c:bf:74:00:37:57` |
| mesh device | `bat0`, a **bridge port** of `br-ahwlan` |
| LAN / mesh v4 | `192.168.12.0/24`, router at `.1` |
| DHCP pool | `.100`-`.249` (laptops) |
| Jetson v4 | `.11` upward, static, from roster position |
| mesh v6 ULA | `fdc7:37f3:e24a::/64`, router at `...:0ebf:74ff:fe00:3757` |
| uplink | `eth0`, DHCP, **IPv4 only** in practice |
| batman | 2023.1-openwrt-7, `BATMAN_IV`, `gw_mode server` |
| hard interface MTU | 1532 |

### The Radio Numbering Is a Trap

UCI's radio index and the phy index do not line up, and the netdev names make it worse:

| UCI | phy | netdev | Band |
| --- | --- | --- | --- |
| `radio0` | phy#1 | `phy1-ap0` | 2.4 GHz |
| `radio1` | phy#2 | `phy2-ap0` | 5 GHz |
| `radio2` | phy#0 | `wlan0` | S1G / HaLow |

So the HaLow radio is `radio2` in UCI but **phy#0**,
and its netdev is plain `wlan0` with no phy prefix.
Do not infer any of these from the others.
The authoritative check is the driver:

```sh
ls -l /sys/class/ieee80211/*/device/driver # only the MM8108 points at morse
morse_cli -i wlan0 version                 # succeeds only against the Morse driver
```

### `network.lan` Is Dead, Ignore It

`uci show network` still lists a `lan` interface at `192.168.8.1` with `ip6assign='60'`.
It has **no device**, there is no `br-lan`, and nothing is on it.
It is GL.iNet's default, left over.
The LAN that exists is `ahwlan`.

Likewise `firewall.@forwarding[0]` is GL.iNet's `lan` -> `wan` rule,
shipped with `enabled '0'`.
Both are inert.
Reading either as live sends you looking for a network that is not there.

## Addressing: Why There Is IPv4

The mesh was designed IPv6-ULA-only, and `README.md` argued the case at length.
That rested on the router having a v6 uplink to masquerade onto.

**It does not.**
`eth0` takes a v4 DHCP lease and a link-local,
with no global v6 and no v6 default route:

```text
2: eth0: inet 192.168.1.27/24
         inet6 fe80::9683:c4ff:fe89:3ce2/64 scope link
default via 192.168.1.1 dev eth0
```

An IPv6-only mesh therefore has no path off this router at all,
whatever batman and the firewall do.
So the mesh is dual stack:

| Family | Where it comes from | What it is for |
| --- | --- | --- |
| IPv6 ULA | static, EUI-64 from the radio MAC | the mesh's own layer; works with no router present |
| IPv4 | static, roster position, `192.168.12.0/24` | the way out, and the way in from a laptop |

Both are stamped into `25-bat0.network` by `install_network_stack.sh`.
The v4 host octets start at `.11` and are bounded below `.100`
so a node can never collide with a laptop's lease.
See `node_mesh_addr4` in `halow-lib.sh`.

The router's own v6 ULA is added by the init script.
**It sits on `bat0`, which is a bridge port**,
and a bridge port does not normally terminate L3 -- frames go to the bridge,
which delivers to the local stack only on its own MAC.
So that address may never answer.
It has not been tested, and nothing depends on it now that v4 carries the uplink.
If you want v6 routing to the router to work,
move it to `br-ahwlan` via `uci set network.ahwlan.ip6addr=...` rather than the script's
`ip -6 addr add`.

## The Bridge

`bat0` is a port of `br-ahwlan`.
This is the single most consequential choice in the whole setup,
it contradicts what earlier versions of this document recommended, and it is deliberate.

**What it buys.**
The Jetsons land in `192.168.12.0/24` alongside the laptops on the APs.
That single fact delivers both of the things the router is for:

- a Jetson reaches the uplink with no per-node routing, no NAT66, and no
  dependence on batman gateway election
- a laptop on `heylo-wifi` runs `ssh user@192.168.12.13` with no jump host, no
  static route, and nothing configured on either end

**What it costs.**
Every broadcast and multicast frame on the LAN -- ARP, mDNS, SSDP,
DHCP -- floods into a 1 MHz channel carrying a few hundred kbit/s. batman says
so itself at boot:

```text
batman_adv: bat0: No IGMP Querier present - multicast optimizations disabled
batman_adv: bat0: No MLD Querier present - multicast optimizations disabled
```

With no querier, batman cannot narrow multicast and floods it.
Three chatty laptops can saturate the link they are supposed to be measuring.

**This cost is unmeasured.**
Nobody has run `batman_oracle.sh tp` before and after.
Do that before scaling past a handful of clients,
and treat any throughput figure taken with laptops on the AP as contaminated.

The routed alternative -- give the LAN its own `/64`
and forward `lan` -> `mesh` -- is what earlier versions of this document insisted on.
It is quieter on the radio and it is strictly more configuration: a prefix,
a forwarding rule, and a return path on every node.
It was never built.
If the broadcast load turns out to matter, that is the direction to go.

## Firewall

Two zones matter and one is a decoy.

| Zone | Networks | input/output/forward |
| --- | --- | --- |
| `wan` | `wan`, `wan6` | REJECT / ACCEPT / REJECT, `masq`, `masq6`, `mtu_fix` |
| `ahwlan` | `ahwlan` | ACCEPT / ACCEPT / ACCEPT |

Plus `forwarding: ahwlan -> wan`, enabled.
That is the entire path out.

**There was a `mesh` zone naming networks `bat0` and `wwan`.**
**Delete it if it is still there.**
Neither network exists any more, so it binds nothing,
and it never carried traffic even when they did: `bat0` is a bridge port,
so mesh packets arrive on `br-ahwlan` and match `ahwlan`.
It reads like the rule making the mesh work and it is not.
That mattered during debugging -- checking a zone whose counters are structurally always
zero.

```sh
uci show firewall | grep -E 'zone.*name|forwarding' # find it, check the index
uci delete firewall.@zone[3]
uci commit firewall
/etc/init.d/firewall restart
```

**NAT66 (`masq6`) is on and currently does nothing**,
because there is no v6 uplink to masquerade onto.
Leave it: it costs nothing and it is what you want the moment the upstream gains IPv6.

### `Section @forwarding[0] is disabled` Is Benign

Every `/etc/init.d/firewall restart` prints it.
It is GL.iNet's own disabled `lan` -> `wan` rule, and it predates everything here.
It appears immediately after whatever you just committed and reads like a report on it.
It is not.
New sections land at the end; the index in the message is not yours.

## Persistence

Attaching the radio to `bat0` is not UCI's job,
and `/etc/rc.local` is the wrong place for it.

**This failed in the field, so be precise about it.**
`rc.local` ran `batctl meshif bat0 interface add wlan0` before `wlan0` existed.
The command failed, boot continued, and the router came up with `bat0` present, up,
bridged and addressed -- carrying no hard interface at all.
The IBSS was still associated,
`iw dev wlan0 station dump` showed the Jetson at a healthy signal,
and every LuCI page looked correct.
The only thing that showed it was `batctl meshif bat0 interface` printing nothing.

Two files in `router/` replace that block:

| File | Job |
| --- | --- |
| `etc/init.d/halow-mesh` | wait for `wlan0` and the bridge, set MTU, attach, `gw_mode server`, bridge and address `bat0` |
| `etc/hotplug.d/net/30-halow-mesh` | re-run the above whenever `wlan0` reappears |

```sh
scp router/etc/init.d/halow-mesh root@192.168.12.1:/etc/init.d/halow-mesh
scp router/etc/hotplug.d/net/30-halow-mesh root@192.168.12.1:/etc/hotplug.d/net/
ssh root@192.168.12.1 'chmod 0755 /etc/init.d/halow-mesh /etc/hotplug.d/net/30-halow-mesh
                       /etc/init.d/halow-mesh enable
                       /etc/init.d/halow-mesh start'
```

Then strip the batman block from `/etc/rc.local`, leaving the header and `exit 0`.
Leaving both is not harmless:
`rc.local` runs first and its bare `interface add` is the call that fails on a re-run.

Two properties make it work, and they are worth preserving in any rewrite:

**It gates rather than orders.**
`start()` waits for the real condition -- the netdev existing --
and fails loudly on timeout.
Same lesson as `halow-wait` on the Jetsons
(see `README.md`): the signals available to order against are lies.

**It is idempotent, so the hotplug rule can fire at any time.**
This is not belt-and-braces, it is load-bearing.
`wlan0` is created and destroyed several times during a normal boot
as netifd configures `radio2` and `wpa_supplicant_s1g` joins the IBSS,
and each destruction silently drops it from batman.
A normal boot looks like this:

```text
15:02:26  netifd: radio2 (2998): Configuring morse device
15:02:27  halow-mesh: added wlan0 to bat0
15:02:28  batman_adv: bat0: Not using interface wlan0 (retrying later)
15:02:28  halow-mesh: added wlan0 to bat0          <- again, after a recreation
15:02:29  halow-mesh: wlan0 is already a bat0 hard interface
15:02:29  batman_adv: bat0: Interface activated: wlan0
```

Repeated adds are the design working, not a fault.
It converges because every recreation fires the rule,
so the script always runs after the last one.

`wpa_supplicant_s1g` and the IBSS interface itself are handled by UCI
(`wireless.radio2` type `morse`, `wireless.wifinet4` mode `adhoc`),
which is a correction to older copies of this document -- see below.

### MTU 1532

batman-adv prepends a 32-byte header.
A 1500-MTU hard interface makes it fragment every full-size frame at layer 2,
and the kernel says so at attach time and then carries on regardless:

```text
batman_adv: bat0: The MTU of interface wlan0 is too small (1500) ... Setting
the MTU to 1532 would solve the problem.
```

Doubling the frame count is affordable on Ethernet
and is not affordable on a 1 MHz link.
The init script sets it before attaching, on every run,
since a recreated `wlan0` comes back at the default.
The Morse driver accepts 1532.

**Both ends must do this** -- batman fragments on the transmitting node,
against its own outgoing interface, so fixing one end only fixes one direction.
The Jetsons already do it in `halow0-ibss.service`; the router was the one missing it.

### `mesh11sd` Must Be Off

It is OpenWrt's 802.11s daemon.
The mesh here is IBSS with `batman-adv` above it; 802.11s is a different,
incompatible mesh at the same layer
(see the design note in `README.md` for why it was not the choice).
It was found running after an unrelated change.

```sh
/etc/init.d/mesh11sd stop
/etc/init.d/mesh11sd disable
```

Disable rather than `opkg remove`, so it is one command to put back.

## Gateway Mode Is a Health Signal, Not a Mechanism

`batctl meshif bat0 gw_mode server` is set, and the Jetsons are `client`.

**It does not install a default route on anyone**,
which is worth being blunt about
because every description of batman gateway mode says it does.
What batman elects a gateway *for* is DHCP:
a client-mode node forwards DHCP to the elected server
and takes its default route from the lease.
This mesh has no DHCP -- addressing is static in both families --
so the election happens, `batctl gwl` fills in, and no route is ever created.

Set it anyway.
`batctl gwl` on a Jetson is the one check
that says "this node can see the uplink from here".
The route itself is `Gateway=` in `25-bat0.network`,
stamped per node by `install_network_stack.sh`.

## Wireless

Both SoC radios sit on `br-ahwlan` with the same encryption and PSK,
so they answer to one name:

```sh
uci set wireless.default_radio0.ssid='heylo-wifi'
uci commit wireless
wifi reload radio0
```

Reload `radio0` alone -- a bare `wifi reload` restarts both radios and drops you
if you are connected over either.
This is two independent APs sharing a name, not a managed roam:
clients pick a band themselves and sometimes pick badly,
and moving between them is a disconnect and reconnect.
No 802.11r/k/v is configured.

The HaLow radio is `radio2` and is driven through UCI as an `adhoc` iface.
Its parameters must match the Jetsons exactly -- SSID, channel, op_class, country,
beacon interval -- and only the address differs.

## Time

The Jetsons have no working RTC and boot to the epoch.
Cross-node measurements are only joinable if their timestamps agree,
so every Jetson is a chrony client of this router
and `batman_oracle.sh soak` refuses to log until chrony reports sync.
That makes this box the fleet's clock authority.
See
[MONITORING.md](MONITORING.md).

```sh
uci set system.ntp.enable_server='1'
uci commit system
/etc/init.d/sysntpd restart
```

No firewall rule is needed: the `ahwlan` zone's input is ACCEPT,
which already admits UDP/123.

**busybox `sysntpd` will not serve time it does not have.**
The GL-MT3000 has no RTC either,
so with the uplink down at boot it comes up at the image's build date
and refuses to be a time source at all.
Every Jetson then free-runs and `soak` will not start.
If the mesh has to work with no uplink, install real chrony:

```sh
opkg install chrony
```

```conf
# /etc/chrony/chrony.conf
local stratum 10          # serve time even with no upstream of our own
allow fdc7:37f3:e24a::/48 # the fleet, and nothing else
```

`local stratum 10` declares this box authoritative on its own say-so.
That is a lie, but a *consistent* one -- every node agrees on the same wrong time,
which is all cross-node joining actually requires.

Over HaLow expect low single-digit milliseconds.
Ample for correlating latency and throughput logs,
nowhere near enough for anything tighter.

## Verify

There is no LuCI page for batman's own tables.

```sh
batctl meshif bat0 interface # expect: wlan0: active
batctl meshif bat0 neighbors
batctl meshif bat0 originators # every node, next hop, link quality
batctl meshif bat0 gwl
iw dev wlan0 station dump # IBSS peers
morse_cli -i wlan0 stats  # PHY-level sanity, incl. temperature
logread -e halow-mesh     # one pattern only; -e does not stack
```

`originators` is the useful one in the field:
it shows multi-hop paths forming and re-forming as nodes move.

Leave the router associated and idle a while before believing any of it.
Association is the easy part.

### End to End, from a Jetson

```sh
ping -I bat0 192.168.12.1 # the router, over the mesh
ping -I bat0 1.1.1.1      # the internet
ssh user@192.168.12.13    # from a laptop on heylo-wifi, the other direction
```

Use `-I bat0` whenever the node also has Ethernet or WiFi up,
or a working reply may have gone out the other interface entirely and tested nothing.

`ping6` to a public resolver fails
and is **not** a broken mesh -- there is no v6 uplink.
`ping6 <node>.mesh` between Jetsons is the v6 test that should pass.

### Where It Breaks

| Symptom | Fault |
| --- | --- |
| `batctl meshif bat0 interface` empty | the radio is detached; `halow-mesh` did not run, or `rc.local` still fights it |
| `batctl o` empty, IBSS associated | same -- L2 is fine, batman is not. This is the silent one |
| no `default via 192.168.12.1` on a Jetson | Jetson: rerun `install_network_stack.sh` |
| router pings, internet does not | router: `ahwlan` -> `wan` forwarding, or `masq` |
| `batctl gwl` empty | `gw_mode server` not set, or mesh not formed |
| names do not resolve, addresses work | DNS, not routing: `resolvectl status bat0` |

## Radio Parameters

US S1G channelisation, `freq_MHz = 902 + 0.5 * channel`:

| Bandwidth | Channel | op_class | Centre | MCS0 sensitivity | MCS0 rate |
| --- | --- | --- | --- | --- | --- |
| 1 MHz | 33 | 68 | 918.5 MHz | -106 dBm | 0.3 Mbps |
| 2 MHz | 10 | 69 | 907 MHz | -103 dBm | 0.7 Mbps |
| 4 MHz | 40 | 70 | 922 MHz | -102 dBm | 1.5 Mbps |
| 8 MHz | 28 | 71 | 916 MHz | -97 dBm | 3.3 Mbps |

Running 1 MHz on channel 33. 1 MHz also reaches MCS10
(-107 dBm), which the wider channels do not have at all.
**This is a fleet-wide decision -- every node must match**,
and a bandwidth change needs both ends reconfigured.

The driver reports S1G channels as their 5 GHz equivalents,
so `iw dev` showing `channel 124 (5620 MHz), width: 20 MHz`
for an S1G channel is expected and is not a misconfiguration.

`s1g_prim_1mhz_chan_index` is the one people lose an evening to.
It is which 1 MHz subchannel of the operating bandwidth is primary,
and it must be less than the operating bandwidth --
so at 1 MHz the only legal value is `0`.
The Morse fork defaults it to `3`, suited to their 8 MHz reference setup,
which fails validation here with `S1G Primary 1MHz index 3 invalid for operating BW 1`;
the network block is then rejected and the radio silently never joins.
Bump it only if the fleet widens: 0-1 at 2 MHz, 0-3 at 4, 0-7 at 8.

### If the Router Associates and Then Falls Over

Check the driver and firmware against a Jetson first:

```sh
morse_cli -i wlan0 version
```

The Jetsons build `morse.ko` from source via DKMS;
the router runs whatever Morse shipped in its image,
so the two drift apart without anyone choosing that.
There is a report on Morse's forum of the MM8108 **2.0.0 driver on OpenWrt 3.1.1
kernel-panicking shortly after two devices associate in IBSS mode**, which the reporter
did not see on 1.17.9.
Morse could not reproduce it and it may not apply here, but "worked at association,
died a minute later" is distinctive enough to recognise rather than rediscover.
The fix is to align the router with the pair the Jetsons are known good on.

## What Changed, and Why

Corrections against earlier versions of this document,
kept because each cost real time to find.

**"UCI does not model the S1G radio; disable it and drive the radio by hand."**
Wrong for this image.
`wireless.radio2` is `type 'morse'` and `wireless.wifinet4` is `mode 'adhoc'`;
netifd creates `wlan0` and starts `wpa_supplicant_s1g` itself.
The by-hand `iw phy ... interface add` and hand-written supplicant conf are not needed.
What *is* outside UCI is attaching the radio to `bat0`,
which is what `halow-mesh` exists for.

**"Name the interface `halow0`, not `wlan0`."**
Good advice on the Jetsons, where the reason is USB-driven predictable naming.
Here netifd names it `wlan0` and it has never collided,
because the SoC radios get `phyN-apN` names.
Not worth changing.

**"Route, do not bridge."** Reversed.
See [The Bridge](#the-bridge) -- bridging is what makes both of the router's jobs work
with no per-node configuration, and the broadcast cost it warned about is real but so
far unmeasured.

**"The mesh is IPv6-only; `ping 8.8.8.8` will never work."**
Was true, is now false, and the reason is the uplink:
no IPv6 on the WAN means an IPv6-only mesh cannot reach anything.
See [Addressing](#addressing-why-there-is-ipv4).

**"Put it in `rc.local`."** Cost a field failure.
See
[Persistence](#persistence).

**"Set up a `mesh` firewall zone for `bat0`."**
It has never carried a packet.
Bridged `bat0` traffic arrives on `br-ahwlan` and matches `ahwlan`.

## Open Questions

- The broadcast cost of the bridge, unmeasured. `batman_oracle.sh tp` with and
  without laptops on the APs.
- Whether the router's v6 ULA on a bridge port answers at all, and whether
  anything should depend on it.
- Whether an IGMP/MLD querier on `br-ahwlan` would let batman re-enable
  multicast optimisation, and what that is worth on a 1 MHz link.
- Which Morse driver/firmware pair the kit image shipped with, against what the
  Jetsons build.
