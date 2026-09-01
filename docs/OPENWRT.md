# Travel Router (OpenWrt) as Mesh Gateway

The router is from the Morse Micro MM8108-EKH19 evaluation kit: a GL.iNet GL-MT3000,
an MM8108 USB 2.0 adapter, an SMA HaLow antenna, and Morse's OpenWrt image
(23.05.5, Morse-2.9.3).
The adapter is USB and hot-pluggable.

The whole fleet is MM8108,
the Jetsons over a Gateworks M.2 module and the router over this kit's USB adapter.
Same silicon, different host interface,
so the radio parameters here are the Jetsons' parameters verbatim.

It does three jobs.
It holds the uplink, and every Jetson routes out through it.
It bridges the mesh onto its own LAN, so a laptop on the AP can reach a Jetson directly.
And it serves time: the Jetsons have no RTC and take their clock from here.

Everything below is shell.
LuCI can express most of it, but the router is worked on over SSH in practice,
and the LuCI paths go stale faster than the commands do.

```sh
ssh root@192.168.12.1
```

For symptoms rather than structure, see
[TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## The Map

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
| mesh device | `bat0`, a bridge port of `br-ahwlan` |
| LAN / mesh v4 | `192.168.12.0/24`, router at `.1` |
| DHCP pool | `.100`-`.249` (laptops) |
| Jetson v4 | `.11` upward, static, from the roster's explicit octet column |
| mesh v6 ULA | `fdc7:37f3:e24a::/64`, router at `...:0ebf:74ff:fe00:3757` on `br-ahwlan` |
| uplink | `eth0`, DHCP, IPv4 only in practice |
| batman | 2023.1-openwrt-7, `BATMAN_IV`, `gw_mode server` |
| hard interface MTU | 1532 |

### The Radio Numbering Is a Trap

UCI's radio index and the phy index do not line up, and the netdev names make it worse:

| UCI | phy | netdev | Band |
| --- | --- | --- | --- |
| `radio0` | phy#1 | `phy1-ap0` | 2.4 GHz |
| `radio1` | phy#2 | `phy2-ap0` | 5 GHz |
| `radio2` | phy#0 | `wlan0` | S1G / HaLow |

The HaLow radio is `radio2` in UCI but phy#0,
and its netdev is plain `wlan0` with no phy prefix.
Do not infer any of these from the others.
Go by the driver:

```sh
ls -l /sys/class/ieee80211/*/device/driver # only the MM8108 points at morse
morse_cli -i wlan0 version                 # succeeds only against the Morse driver
```

### `network.lan` Is Dead, Ignore It

`uci show network` lists a `lan` interface at `192.168.8.1` with `ip6assign='60'`.
It has no device, there is no `br-lan`, and nothing is on it.
It is GL.iNet's default, left over.
The LAN that exists is `ahwlan`.

`firewall.@forwarding[0]` is likewise GL.iNet's `lan` -> `wan` rule,
shipped with `enabled '0'`.
Reading either as live sends you looking for a network that is not there.

## Addressing

The uplink is IPv4 only.
`eth0` takes a v4 DHCP lease and a link-local,
with no global v6 and no v6 default route,
so IPv4 is the family that reaches the internet:

```text
2: eth0: inet 192.168.1.27/24
         inet6 fe80::9683:c4ff:fe89:3ce2/64 scope link
default via 192.168.1.1 dev eth0
```

The mesh is therefore dual stack.
The IPv6 ULA, EUI-64 from each radio's MAC,
is the mesh's own layer and works with no router present.
The IPv4, on `192.168.12.0/24` from the roster's explicit octet column,
is the way out and the way in from a laptop.
Both are stamped into `25-bat0.network` by `install_network_stack.sh`;
v4 host octets start at `.11` and stay below `.100`
so a node cannot collide with a laptop's lease.

### The Router's ULA Lives on `br-ahwlan`

```sh
uci set network.ahwlan.ip6addr='fdc7:37f3:e24a:0:0ebf:74ff:fe00:3757/64'
uci commit network
/etc/init.d/network restart
```

It is on the bridge and not on `bat0`,
because an address on a bridge *port* does not answer:
frames arriving on the port go to the bridge,
which delivers to the local stack only on the bridge's own MAC (`94:83:c4:89:3c:e3`).

It is in UCI and not in `halow-mesh`, because `br-ahwlan` is netifd's interface,
and an address added behind netifd's back is wiped by the next `ifup ahwlan`
or network restart.

This is the router's address on `br-ahwlan`, and the chrony time source the Jetsons'
`GATEWAY_ADDR` points at. It no longer backs a v6 default route: everything else the
Jetsons reach over v6 is already on-link (see the Open Questions entry below).

## The Bridge

`bat0` is a port of `br-ahwlan`,
which puts the Jetsons in `192.168.12.0/24` alongside the laptops on the APs.
That is what delivers both of the things the router is for:
a Jetson reaches the uplink with no per-node routing,
no NAT66 and no dependence on batman gateway election,
and a laptop on `heylo-wifi` runs `ssh robot@192.168.12.13` with no jump host,
no static route, and nothing configured on either end.

The cost is on the radio.
Every broadcast and multicast frame on the LAN, ARP and mDNS and SSDP and DHCP,
floods into a 1 MHz channel carrying a few hundred kbit/s. batman cannot narrow
multicast either, there being no IGMP or MLD querier on the bridge, so it floods that
too.
A few chatty laptops can saturate the link they are supposed to be measuring.

That cost is unmeasured.
Run `batman_oracle.sh tp` with and without clients on the APs
before scaling past a handful,
and treat any throughput figure taken with laptops attached as contaminated.

The routed alternative is to give the LAN its own `/64` and forward `lan` -> `mesh`.
It is quieter on the radio and it is more configuration: a prefix, a forwarding rule,
and a return path on every node.
If the broadcast load turns out to matter, that is the direction to go.

## Firewall

Two zones carry traffic:

| Zone | Networks | input/output/forward |
| --- | --- | --- |
| `wan` | `wan`, `wan6` | REJECT / ACCEPT / REJECT, `masq`, `masq6`, `mtu_fix` |
| `ahwlan` | `ahwlan` | ACCEPT / ACCEPT / ACCEPT |

With `forwarding: ahwlan -> wan` enabled, that is the whole path out.
Mesh packets match `ahwlan`,
since `bat0` is a bridge port and they arrive on `br-ahwlan`.

If a `mesh` zone naming networks `bat0` or `wwan` is still present, delete it.
Those networks no longer exist, so it binds nothing,
and it never carried traffic even when they did:

```sh
uci show firewall | grep -E 'zone.*name|forwarding' # check the index first
uci delete firewall.@zone[3]
uci commit firewall
/etc/init.d/firewall restart
```

NAT66 (`masq6`) is on and currently does nothing,
because there is no v6 uplink to masquerade onto.
Leave it: it costs nothing and it is what you want the moment the upstream gains IPv6.

## Persistence

Attaching the radio to `bat0` is not UCI's job,
and `/etc/rc.local` is the wrong place for it: a USB radio enumerates asynchronously,
so no fixed point in boot is reliably after `wlan0` exists.

Two files in `router/` do it instead:

| File | Job |
| --- | --- |
| `etc/init.d/halow-mesh` | wait for `wlan0` and the bridge, set MTU, attach, `gw_mode server`, bridge `bat0` |
| `etc/hotplug.d/net/30-halow-mesh` | re-run the above whenever `wlan0` reappears |

```sh
scp router/etc/init.d/halow-mesh root@192.168.12.1:/etc/init.d/halow-mesh
scp router/etc/hotplug.d/net/30-halow-mesh root@192.168.12.1:/etc/hotplug.d/net/
ssh root@192.168.12.1 'chmod 0755 /etc/init.d/halow-mesh /etc/hotplug.d/net/30-halow-mesh
                       /etc/init.d/halow-mesh enable
                       /etc/init.d/halow-mesh start'
```

`/etc/rc.local` must carry no batman lines.
It runs first, and its bare `interface add` is the call that fails on a re-run.

Two properties matter if either file is ever rewritten.

`start()` gates on the real condition, the netdev existing, and fails loudly on timeout.
Same reasoning as `halow-wait` on the Jetsons (see `README.md`).

`start()` is also idempotent,
which is what makes the hotplug rule safe to fire at any time.
`wlan0` is created and destroyed several times during a normal boot
as netifd configures `radio2` and `wpa_supplicant_s1g` joins the IBSS,
and each destruction drops it from batman.
Every recreation fires the rule, so the script runs again and converges.

Verify:

```sh
logread -e halow-mesh          # one pattern only; -e does not stack
batctl meshif bat0 interface   # expect: wlan0: active
ls /etc/rc.d/ | grep halow     # expect S95halow-mesh and K10halow-mesh
```

### MTU 1532

batman-adv prepends a 32-byte header,
so a 1500-MTU hard interface fragments every full-size frame at layer 2.
Doubling the frame count is affordable on Ethernet
and is not affordable on a 1 MHz link.

The init script sets it before attaching, on every run,
since a recreated `wlan0` comes back at the default.
The Morse driver accepts 1532.

Both ends need it. batman fragments on the transmitting node against its own outgoing
interface, so fixing one end fixes one direction.
The Jetsons do it in `halow0-ibss.service`.

### `mesh11sd` Must Be Off

It is OpenWrt's 802.11s daemon.
The mesh here is IBSS with `batman-adv` above it, and 802.11s is a different,
incompatible mesh at the same layer
(see the design note in `README.md` for why it was not the choice).

```sh
/etc/init.d/mesh11sd stop
/etc/init.d/mesh11sd disable
```

Disable it, so it is one command to put back.

## Gateway Mode

`batctl meshif bat0 gw_mode server` is set, and the Jetsons are `client`.

It does not install a default route on anyone,
which is worth stating because most descriptions of batman gateway mode say it does.
What batman elects a gateway *for* is DHCP:
a client-mode node forwards DHCP to the elected server
and takes its default route from the lease.
This mesh has no DHCP, addressing being static in both families,
so the election happens, `batctl gwl` fills in, and no route is ever created.

It is still worth setting.
`batctl gwl` on a Jetson tells you that node can see the uplink.
The route itself is the IPv4 `Gateway=` in `25-bat0.network`,
stamped per node by `install_network_stack.sh`. There is no IPv6 equivalent:
the router has no v6 uplink to forward onto, so a v6 default route here would
have nowhere to go.

## Wireless

Both SoC radios sit on `br-ahwlan` with the same encryption and PSK,
so they answer to one name:

```sh
uci set wireless.default_radio0.ssid='heylo-wifi'
uci commit wireless
wifi reload radio0
```

Reload `radio0` alone.
A bare `wifi reload` restarts both radios and drops you
if you are connected over either.

This is two independent APs sharing a name.
Nothing coordinates them.
Clients pick a band themselves and sometimes pick badly,
and moving between them is a disconnect and reconnect.
No 802.11r/k/v is configured.

The HaLow radio is `radio2`, driven through UCI as an `adhoc` iface.
Its parameters must match the Jetsons exactly,
SSID and channel and op_class and country and beacon interval,
with only the address differing.

## Time

The Jetsons have no working RTC and boot to the epoch.
Cross-node measurements are only joinable if their timestamps agree,
so every Jetson is a chrony client of this router
and `batman_oracle.sh soak` refuses to log until chrony reports sync.
That makes this box the fleet's clock authority.
See [MONITORING.md](MONITORING.md).

```sh
uci set system.ntp.enable_server='1'
uci commit system
/etc/init.d/sysntpd restart
```

No firewall rule is needed: the `ahwlan` zone's input is ACCEPT,
which already admits UDP/123.

busybox `sysntpd` will not serve time it does not have.
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
That is a lie, but a consistent one: every node agrees on the same wrong time,
which is all cross-node joining requires.

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
```

`originators` is the useful one in the field:
it shows multi-hop paths forming and re-forming as nodes move.

Leave the router associated and idle a while before believing any of it.
Association is the easy part.

From a Jetson, the other direction:

```sh
ping -I bat0 192.168.12.1 # the router, over the mesh
ping -I bat0 1.1.1.1      # the internet
ssh robot@192.168.12.13   # from a laptop on heylo-wifi
```

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
This is a fleet-wide decision, so every node must match,
and a bandwidth change needs both ends reconfigured.

`s1g_prim_1mhz_chan_index` is
which 1 MHz subchannel of the operating bandwidth is primary,
and it must be less than the operating bandwidth: 0 at 1 MHz, 0-1 at 2 MHz, 0-3 at 4,
0-7 at 8.
The Morse fork defaults it to `3`,
which is wrong for this fleet and fails validation rather than warning.

## Open Questions

- The broadcast cost of the bridge, unmeasured. `batman_oracle.sh tp` with and
  without laptops on the APs.
- Whether anything should depend on the router's v6 ULA.
  The Jetsons' chrony time source points at it,
  but the v6 default route that used to point at it has been removed:
  v4 carries the uplink, and a v6 default route would have had no v6 upstream to reach.
- Whether an IGMP/MLD querier on `br-ahwlan` would let batman re-enable
  multicast optimisation, and what that is worth on a 1 MHz link.
- Which Morse driver/firmware pair the kit image shipped with, against what the
  Jetsons build.
