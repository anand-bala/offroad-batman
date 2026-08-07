# Travel Router (OpenWrt) as Mesh Gateway

The router is the one from the **Morse Micro MM8108-EKH19 evaluation kit**:
a GL.iNet GL-MT3000 travel router, an MM8108 USB 2.0 network adapter,
an SMA HaLow antenna, and a Morse Micro OpenWrt image for the router.
The adapter is USB and hot-pluggable,
so it can be added and removed without rebooting the router.

The whole fleet is **MM8108**: the Jetsons over a Gateworks M.2 module,
the router over this kit's USB adapter.
Same silicon, different host interface,
so the radio parameters below are the Jetsons' parameters verbatim.

Its job in the deployed network is **gateway**:
it has an uplink connection and announces itself through batman-adv,
so any Jetson reaches the internet from wherever it is, over however many hops.

The kit ships configured for HaLow AP/STA,
which cannot interoperate with the IBSS cell the Jetsons form.
Converting it is what this document is about.
Do this only after the Jetson-to-Jetson IBSS gate passes (see `README.md`).
Until then the router is a working debug bridge and is worth leaving alone.

> All of this has been run against the router: the Jetsons mesh to it,
> the `mesh` zone forwards to `wan`, and NAT66 is on.
> The router side is done.
> What was actually missing when the mesh first had no internet was on the
> **Jetsons** -- no default route, because batman gateway mode does not create
> one here. See step 5, which is the part most likely to mislead.
> Keep console/LAN access -- the wireless reconfiguration will drop you.

The router is configured through **LuCI**,
the OpenWrt web UI that the Morse image is built on, at `http://192.168.8.1`
(the GL-MT3000 default) wherever that is possible.
Two things genuinely cannot be done there and are called out where they come up:
the S1G radio itself (UCI does not model it) and the `batctl` status commands.
Everything else -- packages, the batman interface, gateway mode, firewall,
persistence -- is LuCI work.
Shell equivalents are given alongside each step for
when you are on the console rather than in a browser;
they are the same settings by another route, not extra steps.

## 0. Identify the Radio

The GL-MT3000 has two radios of its own
(2.4 and 5 GHz, on the SoC)
before the MM8108 adapter is plugged in, so nothing here can assume a name.
There is no fixed answer to what the HaLow radio is called:
it depends on enumeration order, on whether the adapter was present at boot,
and on what the image already had configured.
Work it out on the box, once, and carry the answers through the rest of this document.

Three names are needed, and they are three different things:

| Placeholder | What it is | Where it is used |
| --- | --- | --- |
| `$RADIO` | the UCI *wifi-device* section (`radio0`, `radio1`, ...) | step 1, LuCI's Wireless page |
| `$PHY` | the mac80211 phy (`phy0`, `phy1`, ...) | step 3, creating the interface |
| `$IFACE` | the netdev (`wlan0`, `wlan1`, ...) | steps 3-7, everything after |

### On the Command Line

Start from the fact that the MM8108 is the only radio on USB.
That is the cleanest discriminator on this box:

```sh
lsusb                                      # expect a Morse Micro device, VID 325b
ls -l /sys/class/ieee80211/*/device/driver # phy -> driver; look for morse
```

The second command is the authoritative one: it maps each phy to the driver behind it,
and only the MM8108's phy points at the Morse driver.
Whatever phy that is, is `$PHY`.

Then find what is on that phy:

```sh
iw dev           # interfaces grouped under their phy, with type
iw phy "$PHY" info # capabilities of that phy alone
```

`iw dev` is the reliable enumerator
for wireless netdevs -- prefer it over looking in `/sys/class/net`.
If the adapter has an interface already
(the kit ships it in AP or STA mode),
it will show here with `type AP` or `type managed`;
that is the interface the kit image configured, not the one this document wants.
Step 3 creates a new one.

For the UCI side:

```sh
uci show wireless # wifi-device sections, each with a path and type
```

Match the section whose `option path` is a USB path
(it will contain `usb`) rather than a PCIe one -- that is `$RADIO`.
If the image named its sections descriptively rather than `radio0`/`radio1`,
take the name as it appears; UCI does not require the `radioN` form.

### In LuCI

Network > Wireless lists the radios.
Each row is labelled with its phy and its driver/band description,
which is the join back to the command line:
find the row whose phy matches the `$PHY` you just identified.
The two SoC radios will describe themselves as ordinary 802.11 b/g/n/ac/ax;
the MM8108's row is the one that does not,
and on the Morse image it is usually labelled as HaLow or 802.11ah.

Do not go by band or channel number in the UI.
The driver reports S1G channels as their 5 GHz equivalents,
so the HaLow radio can appear to be a second 5 GHz radio -- see the note in step 3.

If exactly one row is unaccounted for after identifying the two SoC radios, that is it.
Confirm with `morse_cli` before acting on the guess:

```sh
morse_cli -i "$IFACE" version # succeeds only against the Morse driver
```

That command failing on an interface is a good sign you have the wrong one.

## 0B. Check the Driver Against a Jetson

IBSS on the MM8108 is proven -- the Jetsons run it.
What is not proven is *this* driver and firmware build doing it,
and that is the one thing worth checking before starting:

```sh
morse_cli -i "$IFACE" version                              # driver and firmware versions
iw phy "$PHY" info | grep -A12 'Supported interface modes' # IBSS should be listed
```

Compare against a Jetson.
The Jetsons build `morse.ko` from source via DKMS (`build_dependencies.sh`);
the router runs whatever Morse shipped in its OpenWrt image,
so the two can drift apart without anyone choosing that.

If the router associates and then falls over, this is the first thing to suspect.
There is a report on Morse's forum of the MM8108 **2.0.0 driver on OpenWrt 3.1.1
kernel-panicking shortly after two devices associate in ad-hoc/IBSS mode**, which the
reporter did not see on the older 1.17.9 driver.
Morse could not reproduce it,
and it may well not apply here -- but "worked at association,
died a minute later" is a distinctive enough symptom to be worth recognising rather than
rediscovering.
The fix in that case is to align the router with the driver/firmware pair the Jetsons
are known good on.

## 1. Take UCI off the HaLow Radio

The UCI/LuCI wireless layer does not model the S1G features,
so drive the radio with the `_s1g` tools directly and leave UCI to manage bridges,
firewall and the uplink.

**LuCI:** Network > Wireless.
On the `$RADIO` row identified in step 0, press **Disable**.
Check twice that it is that row
and not one of the SoC radios -- disabling the wrong one is how you lose your way into
the box.
The radio stays down as far as netifd is concerned;
`wpa_supplicant_s1g` will drive it directly in step 3.

Shell equivalent:

```sh
uci set wireless."$RADIO".disabled='1'
uci commit wireless
wifi reload
```

The router's own 2.4/5 GHz radios are untouched by this and stay useful as your way in.

## 2. Packages

**LuCI:** System > Software.
Press **Update lists**, then install:

| Package | Why |
| --- | --- |
| `kmod-batman-adv` | the mesh routing module |
| `batctl` | mesh status and control |
| `luci-proto-batadv` | adds batman-adv to LuCI's protocol list (step 4) |
| `luci-app-commands` | optional; puts the step 6 checks behind buttons |

`luci-proto-batadv` is the one
that matters here -- without it batman-adv has no LuCI presence at all
and step 4 has to be done by hand in UCI.
Install it before going any further.

Shell equivalent:

```sh
opkg update
opkg install kmod-batman-adv batctl luci-proto-batadv luci-app-commands
```

The Morse packages (`wpa_supplicant_s1g`, `hostapd_s1g`, `morse_cli`,
the MM8108 firmware and driver) are already on the kit image --
that is the point of using it rather than stock GL.iNet or vanilla OpenWrt.
If a package is missing, it comes from Morse Micro's image, not from the OpenWrt feeds;
reflash rather than hunt for it.

Note that the IBSS interface does not exist yet,
so it will not appear in LuCI's device dropdowns until step 3 has created it.

## 3. IBSS Interface (Not LuCI)

This is the one step with no web UI.
LuCI's wireless pages are built on UCI's `wireless` config,
which is exactly the layer that does not understand S1G,
so the interface and its supplicant are created by hand.
LuCI regains control at step 4.

Parameters must match the Jetsons **exactly** -- SSID, channel, op_class, country,
beacon interval.
Only the IP differs.

Set the names from step 0 first, so the rest is copy-pasteable:

```sh
for p in /sys/class/ieee80211/*; do
  case "$(readlink -f "$p/device/driver")" in
  *morse*) PHY=$(basename "$p") ;;
  esac
done
IFACE=halow0
echo "using $PHY -> $IFACE"
```

Pick the interface name yourself rather than letting the kernel pick.
`wlan0` is a poor choice: it is in the kernel's own namespace
and can collide with an SoC radio's interface.
The Jetsons use `halow0` for exactly this reason
(see `README.md`),
and matching that name here means one less thing that differs between node types.

```sh
iw phy "$PHY" interface add "$IFACE" type ibss
ip link set "$IFACE" up

cat >/etc/wpa_supplicant_s1g_ibss.conf <<'EOF'
country=US
ctrl_interface=/run/wpa_supplicant_s1g
ap_scan=2

network={
        ssid="HaLow-Mesh"
        mode=1
        channel=33
        op_class=68
        s1g_prim_1mhz_chan_index=0
        country="US"
        beacon_int=1000
        key_mgmt=NONE
}
EOF

wpa_supplicant_s1g -i "$IFACE" -c /etc/wpa_supplicant_s1g_ibss.conf -B
```

There is no file editor in stock LuCI,
so write the config over SSH/console
or `scp` it from a Jetson -- it is the same file the Jetsons use, minus the address.

That is `etc/wpa_supplicant/wpa_supplicant-halow0.conf` with the comments stripped --
copy it rather than retyping, and re-copy it whenever the fleet's parameters change.

`s1g_prim_1mhz_chan_index` is the one people lose an evening to.
It is which 1 MHz subchannel of the operating bandwidth is primary,
and it must be less than the operating bandwidth,
so at 1 MHz the only legal value is `0`.
The Morse fork defaults it to `3`, suited to their own 8 MHz reference setup,
which fails validation here with `S1G Primary 1MHz index 3 invalid for operating BW 1`;
the network block is then rejected and the radio silently never joins.
Bump it only if the fleet widens: 0-1 at 2 MHz, 0-3 at 4, 0-7 at 8.

US S1G channelisation; the frequency mapping is `freq_MHz = 902 + 0.5 * channel`:

| Bandwidth | Channel | op_class | Centre |
| --- | --- | --- | --- |
| 1 MHz | 33 | 68 | 918.5 MHz |
| 2 MHz | 10 | 69 | 907 MHz |
| 4 MHz | 40 | 70 | 922 MHz |
| 8 MHz | 28 | 71 | 916 MHz |

The radio reports S1G channels as their 5 GHz equivalents,
so `iw dev` showing `channel 100 (5500 MHz), width: 160 MHz`
for an 8 MHz S1G channel is expected.

For encrypted IBSS, replace `key_mgmt=NONE` with the RSN block commented out in
`etc/wpa_supplicant/wpa_supplicant-halow0.conf` and use the same PSK fleet-wide.
Note this is RSN-IBSS, not SAE -- see the security notes in `README.md`.

## 4. Batman-Adv on Top

With `luci-proto-batadv` installed this is two interfaces in Network > Interfaces.

**The mesh itself.**
*Add new interface*, name it `bat0`, protocol **Batman Mesh**, device left empty.
On its *General Settings* tab set the routing algorithm to `BATMAN_IV`
(the default, and what the Jetsons run -- both ends must agree).
Address it on the fleet's IPv6 ULA prefix, matching `install_network_stack.sh`;
a wrong prefix silently partitions the mesh rather than failing.

**The radio's membership in it.**
*Add new interface* again, name it something like `bat0_hardif`,
protocol **Batman Mesh Hardif**, device `$IFACE`, master interface `bat0`.
That is the LuCI expression of `batctl meshif bat0 interface add $IFACE`.

Because `$IFACE` is created outside UCI in step 3,
it will not be in the device dropdown until it exists -- create it first,
then reload the page. netifd picks the interface up by hotplug,
so on a cold boot the ordering in step 7 matters.
The adapter itself is hot-pluggable, which helps here:
unplugging and replugging it is a legitimate way to re-trigger the whole chain
while debugging.

Shell equivalent:

```sh
modprobe batman-adv
batctl meshif bat0 interface add "$IFACE"
ip link set bat0 up
ip -6 addr add dev bat0 <ULA >/64
```

`$IFACE` carries only batman traffic from here on -- do not put an IP on it
and do not bridge it directly.
Bridge `bat0` if you need to; that is an ordinary LuCI bridge on the `bat0` interface.

## 5. Gateway Announcement

On the router, in Network > Interfaces,
edit `bat0` and set **Gateway mode** to `server` on the Batman Mesh settings.
The related fields (announced up/down bandwidth) can stay at their defaults
unless you want to weight the election.

On each Jetson the same setting is `client`, which is `batctl` there rather than LuCI:

```sh
batctl meshif bat0 gw_mode client
```

Shell equivalent on the router:

```sh
batctl meshif bat0 gw_mode server
```

**Gateway mode does not install a default route here.**
It is worth being blunt about this,
because the usual description of batman gateway mode says it does.
What batman actually elects a gateway *for* is **DHCP**:
a client-mode node forwards its DHCP traffic to the elected server
and takes its default route from the lease.
This mesh has no DHCP at all -- addressing is static ULA,
naming is mDNS -- so the election happens, `batctl gwl` fills in,
and no route is ever created.

So gateway mode here is **a health signal, not a mechanism**.
It is still worth setting, because `batctl gwl` on a Jetson
is the one check that says "this node can see the uplink",
but the route itself is static, in `Gateway=` in `25-bat0.network`,
stamped per node by `install_network_stack.sh` (see `README.md`).

## 5B. Firewall and NAT66

Two separate things are needed here and only the first is obvious.
Both are already configured on the current router;
this section is the record of what was set, and what to check if it regresses.

**Forwarding.** `bat0` needs a zone, and that zone needs to forward to `wan`.

**NAT66.** The mesh is ULA (`fd..`), which is not internet-routable.
Without masquerading, packets leave with an `fd..` source
and no reply can ever come back.
This is the half people miss,
because the v4 `masq` on the WAN zone is on by default and the v6 `masq6` is not.

**LuCI:** Network > Firewall > Zones.
*Add* a zone named `mesh`, covered network `bat0`,
input/output `accept`, forward `reject`,
and tick **Allow forward to destination zones: wan**.
Then edit the existing `wan` zone and tick **IPv6 Masquerading**.

Shell equivalent:

```sh
uci add firewall zone
uci set firewall.@zone[-1].name='mesh'
uci set firewall.@zone[-1].network='bat0'
uci set firewall.@zone[-1].input='ACCEPT'
uci set firewall.@zone[-1].output='ACCEPT'
uci set firewall.@zone[-1].forward='REJECT'

uci add firewall forwarding
uci set firewall.@forwarding[-1].src='mesh'
uci set firewall.@forwarding[-1].dest='wan'

# NAT66 on the wan zone, found by name rather than by index -- the index
# differs between images and setting masq6 on the wrong zone is silent.
WAN=$(uci show firewall | sed -n "s/^firewall\.\(@zone\[[0-9]*\]\)\.name='wan'$/\1/p")
uci set firewall."$WAN".masq6='1'

uci commit firewall
/etc/init.d/firewall restart
```

`option forward` on the zone is intra-zone traffic (mesh node to mesh node
*through the router*), not the way out;
`REJECT` is correct there, since the Jetsons reach each other over batman
directly and never transit the router.
The way out is the separate `forwarding` section.

Confirm the NAT rule actually exists rather than trusting the commit:

```sh
nft list ruleset | grep -i masquerade # expect an ip6 rule, not just ip
fw4 print | grep -A5 'chain srcnat'
```

### The "Section Is Disabled" Message Is Expected

Every `/etc/init.d/firewall restart` on this router prints:

```
Section @forwarding[0] is disabled, ignoring section
```

**This is benign and predates anything in this document.**
`@forwarding[0]` is GL.iNet's own `lan` -> `wan` rule,
shipped with `option enabled '0'` because the GL.iNet layer manages LAN
forwarding itself. It is not the mesh rule.

Worth writing down because the message appears immediately after the commit
that adds the mesh rule, reads like a report on it, and sends you rechecking
a firewall that is correct.
The index in the message is the section `fw4` rejected,
which is not the one you just added -- new sections land at the end.

Check which section is actually meant before believing it:

```sh
uci show firewall | grep -E 'forwarding|zone.*name'
```

On the current router that gives `@forwarding[0]` as the disabled GL.iNet
`lan` -> `wan`, `@forwarding[1]` as `ahwlan` -> `wan`,
and `@forwarding[2]` as the `mesh` -> `wan` rule from this section,
with no `enabled` option, which means on.
Zones are `@zone[0]` lan, `@zone[1]` wan, `@zone[3]` mesh.

If a message ever does name the mesh rule, the causes in order are:
a `src`/`dest` that matches no zone's `option name`,
an explicit `option enabled '0'`,
or a half-built section from an interrupted `uci add`
(delete it with `uci delete firewall.@forwarding[N]` and redo).

## 5C. Serving Time to the Mesh

The Jetsons have no working RTC and boot to the Unix epoch.
Measurements taken on different nodes are only joinable
if their timestamps mean the same thing,
so `install_network_stack.sh` configures every Jetson as a chrony client
of **this router**, and `batman_oracle.sh soak` refuses to log until
chrony reports the clock is synced.
That makes the router the fleet's clock authority.
See [MONITORING.md](MONITORING.md) for the whole picture.

**The router does not need chrony.**
NTP is a wire protocol and the clients do not care what serves it.
OpenWrt already ships busybox `sysntpd`, which only needs to be told to serve:

**LuCI:** System > System > Time Synchronization,
tick **Provide NTP server**.

```sh
uci set system.ntp.enable_server='1'
uci commit system
/etc/init.d/sysntpd restart
```

No firewall rule is needed *provided* you built the `mesh` zone as in 5B --
its `input` is `ACCEPT`, which already admits UDP/123.
If you tightened that, add an explicit rule for port 123 from `mesh`.

`fake-hwclock` has no OpenWrt equivalent to install:
`/etc/init.d/sysfixtime` is already there
and restores the clock at boot from the newest file mtime on the filesystem.

### The Offline Case

**busybox `sysntpd` will not serve time it does not have.**
The GL-MT3000 has no RTC either,
so with the uplink down at boot it comes up at the image's build date
and simply refuses to be a time source until Starlink is up.
Every Jetson then free-runs and `soak` will not start.

If the mesh has to work with no uplink, that is not good enough,
and the router needs real chrony:

```sh
opkg install chrony
```

```conf
# /etc/chrony/chrony.conf additions
local stratum 10          # serve time even with no upstream of our own
allow fdc7:37f3:e24a::/48 # the fleet, and nothing else
```

`local stratum 10` is the whole point:
it declares this box authoritative on its own say-so.
That is a lie, but a *consistent* one --
every node agrees on the same wrong time,
which is all that cross-node joining actually requires.
Without it there is no ground truth anywhere and the nodes agree on nothing.

Confirm the package feeds are configured before relying on this;
the Morse packages come from the kit image rather than the OpenWrt feeds
(see step 2), and `chrony` comes from the feeds.

### Verify

From a Jetson, after the router is serving:

```sh
chronyc sources -v # '^*' marks the selected server; expect the router
chronyc tracking   # 'Last offset' and 'RMS offset' should be small
```

Over HaLow expect **low single-digit milliseconds**.
That is ample for correlating latency and throughput logs
and nowhere near enough for anything tighter.

## 5D. Getting a Laptop onto the Mesh

`batman_oracle.sh` is normally run from a laptop
plugged into this router's Ethernet.
The laptop has no HaLow radio, so it drives the nodes over ssh --
which means it needs to reach the mesh's ULA addresses.

**Route, do not bridge.**
LuCI will happily let you add `bat0` to `br-lan`,
and it looks like the shortest path to the answer.
Do not.
`br-lan` carries the router's own 2.4 and 5 GHz APs,
and bridging pushes every LAN broadcast and multicast frame
into a 1 MHz channel with a few hundred kbit/s of total capacity.
One chatty laptop can saturate the mesh it is supposed to be measuring.

Give the LAN its own `/64` out of the same `/48` instead:

```sh
uci set network.lan.ip6addr='fdc7:37f3:e24a:1::1/64'
uci set network.lan.ip6assign='64'
uci commit network
/etc/init.d/network restart
```

Then allow the LAN to reach the mesh:

```sh
uci add firewall forwarding
uci set firewall.@forwarding[-1].src='lan'
uci set firewall.@forwarding[-1].dest='mesh'
uci commit firewall
/etc/init.d/firewall restart
```

**The return path needs no per-node configuration**,
which is the reason to do it this way.
Every Jetson already carries a static default route to this router
(`Gateway=` in `25-bat0.network`, stamped by `install_network_stack.sh`),
so replies to `fdc7:37f3:e24a:1::/64` follow it back here without being told to.
Note the mesh is `...:0::/64` and the LAN is `...:1::/64` --
distinct `/64`s under one `/48`, so nothing overlaps.

On the laptop, take the fleet's names from the roster
rather than copying anyone's `/etc/hosts`:

```sh
./batman_oracle.sh hosts | sudo tee -a /etc/hosts
ssh-copy-id <user>@olo.mesh   # once per node; the oracle needs BatchMode ssh
```

Then check the whole fleet from the laptop:

```sh
./batman_oracle.sh status
```

Everything the oracle reports is measured **on** a node, not on the laptop.
A ping issued from the laptop would cross Ethernet and this router
before touching a radio,
and would say nothing about the hop under test.

## 6. Verify

LuCI covers the surrounding network state -- Status > Overview for interface state,
Network > Interfaces for whether `bat0` and the hardif came up,
Status > Routes for what the router thinks it can reach -- but there is no LuCI page
for batman's own tables.
Those stay `batctl`:

```sh
iw dev "$IFACE" station dump     # IBSS peers, should list the Jetsons
batctl meshif bat0 neighbors   # direct batman neighbours
batctl meshif bat0 originators # every node, with next hop and link quality
batctl meshif bat0 gwl         # gateway list
morse_cli -i "$IFACE" stats      # PHY-level sanity, incl. temperature
```

With `luci-app-commands` from step 2 you can save each of these under System > Custom
Commands and run them from the browser, which is worth the five minutes if you are going
to be watching the mesh from a laptop in the field.

`originators` is the useful one in the field:
it shows multi-hop paths forming and re-forming as nodes move,
which is the whole point of the exercise.

Leave the router associated and idle for a while before believing any of it.
Association is the easy part, and the failure mode in section 0 shows up minutes later.

### End to End, from a Jetson

The above only proves the router's view. The actual goal is a Jetson reaching
the internet, and that is tested from the Jetson, not here:

```sh
ping6 -I bat0 2606:4700:4700::1111 # Cloudflare; there is no IPv4 on the mesh
```

`ping 8.8.8.8` fails on a perfectly healthy setup -- `bat0` is IPv6-only,
so there is no v4 source address to send from. See `README.md`.

Where it breaks tells you which half is wrong:

| Symptom on a Jetson | Where the fault is |
| --- | --- |
| no `default via .. dev bat0` | Jetson: rerun `install_network_stack.sh` |
| `batctl gwl` empty | router: `gw_mode server` not set, or mesh not formed |
| `heylo-base.mesh` pings, resolvers do not | router: this section -- forwarding or `masq6` |
| resolvers ping, names do not resolve | DNS, not routing: `resolvectl status bat0` |

The third row is the one worth recognising:
mesh perfect, uplink perfect, and nothing works,
because ULA packets left the router unmasqueraded and no reply could return.

## 7. Persistence

Step 4 and step 5 are already persistent -- LuCI wrote them to `/etc/config/network`,
and netifd replays them on boot.
Step 3 is not: the interface creation and `wpa_supplicant_s1g` are outside UCI
and have to be re-run.

**LuCI:** System > Startup, *Local Startup* tab, which is `/etc/rc.local` in a text box.
Put the `iw phy ... interface add` and `wpa_supplicant_s1g` lines there,
above the `exit 0`.
`bat0` and its hardif then come up on their own once `$IFACE` appears.

Include the phy-detection loop from step 3 rather than a literal phy name.
A USB adapter can enumerate in a different order across reboots,
and a boot script that hardcodes `phy1` will one day create the IBSS interface on one of
the SoC radios instead.
`$IFACE` is safe to hardcode -- you chose it.

Deliberately leave this until the parameters stop changing -- a half-working config
that auto-starts on boot is harder to debug than one you invoke by hand.
If `rc.local` proves too early or too late in boot -- a real risk with a USB adapter
that enumerates asynchronously -- promote it to a procd init script,
which the same page lists under *Initscripts*, or trigger it from a USB hotplug rule.

## Bandwidth

The MM8108 MCS0 receive sensitivities, from the kit's product brief:

| Bandwidth | MCS0 sensitivity | MCS0 rate |
| --- | --- | --- |
| 1 MHz | -106 dBm | 0.3 Mbps |
| 2 MHz | -103 dBm | 0.7 Mbps |
| 4 MHz | -102 dBm | 1.5 Mbps |
| 8 MHz | -97 dBm | 3.3 Mbps |

That is the ~9 dB the `README.md` design notes spend on 8 MHz,
measured rather than estimated. 1 MHz also reaches MCS10
(-107 dBm), which the wider channels do not have at all.
This is a fleet-wide decision -- every node must match.

## Open Questions

- Which Morse driver/firmware pair the kit image shipped with,
  and whether it matches what the Jetsons build.
  Same chip, but independently versioned software stacks -- see section 0.
- Whether the M.2 and USB hosts differ anywhere that matters at the radio level.
  They should not; the parameters are identical and the silicon is the same.
