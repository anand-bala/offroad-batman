# Troubleshooting

Symptoms that have actually occurred on this fleet, and what each one turned out to be.

The other documents describe how the system is built now.
This one is for when it is not behaving that way.
Everything here is a real failure that cost time to diagnose;
none of it is hypothetical.

Start here:

```sh
./batman_oracle.sh status        # whole-fleet health, from the laptop
batctl o                         # on any node: who can it see?
batctl meshif bat0 interface     # on the router: expect "wlan0: active"
```

## Contents

- [The mesh is down](#the-mesh-is-down)
- [The mesh is up but there is no internet](#the-mesh-is-up-but-there-is-no-internet)
- [Names do not resolve](#names-do-not-resolve)
- [The radio behaves oddly](#the-radio-behaves-oddly)
- [Measurements look wrong](#measurements-look-wrong)
- [Messages that look alarming and are not](#messages-that-look-alarming-and-are-not)

---

## The Mesh Is Down

### `batctl o` Is Empty, but `iw station dump` Lists the Peer

`bat0` has no hard interface.
Layer 2 is fine, the IBSS is associated, the signal is healthy,
and every status page looks correct.
Nothing routes.

On the router:

```sh
batctl meshif bat0 interface     # empty is the fault; expect "wlan0: active"
batctl meshif bat0 interface add wlan0
```

This happened because `/etc/rc.local` ran `batctl meshif bat0 interface add wlan0`
before `wlan0` existed.
The command failed, boot continued, and the router came up with `bat0` present, up,
bridged and addressed, carrying no hard interface at all.
A USB radio enumerates asynchronously,
so no fixed point in boot can be relied on to be after that.

`/etc/init.d/halow-mesh` replaces that block and waits for the netdev.
If this recurs, check that the init script is installed and enabled,
and that the old batman lines are gone from `rc.local`:

```sh
ls /etc/rc.d/ | grep halow       # expect S95halow-mesh and K10halow-mesh
grep -c batctl /etc/rc.local     # expect 0
logread -e halow-mesh
```

### Both Units Are Green After a Reboot and There Is Still No Mesh

On a Jetson, this was a boot race that ordering could not fix,
because the signals systemd had to order against were lies.

`iw reg set` returns once the request is queued,
so the supplicant could enumerate channels while the domain was still world-roaming
and find the S1G channel disallowed.
It does not exit over that, it just never joins, so `Restart=on-failure` never fired.
And `halow0-ibss` is `Type=simple`,
so it counted as started the instant `wpa_supplicant_s1g` forked,
long before it had taken the link down, set type IBSS and joined.
`halow0-attach` enslaved to `bat0` inside that window and got a slave
that never carried anything.

Both units now gate on the real condition via `usr/local/lib/halow/halow-wait`
(`regdom`, `joined`).
If it recurs, the journal shows a retry loop:

```sh
systemctl status halow0-ibss halow0-attach
journalctl -b -u halow0-ibss -u halow0-attach --no-pager
iw reg get; rfkill list      # domain "00", or a soft block
ip -d link show halow0       # master bat0? type ibss?
```

Capture that before restarting anything.
A restart destroys the evidence.

### Restarting the Supplicant Detached the Radio from `bat0`

Expected, and forced by the unit wiring.
`halow0-attach` is `PartOf=halow0-ibss`.
`Requires=` forwards an explicit stop but *not* a restart,
so restarting the supplicant used to run attach's `ExecStop` (`nomaster`)
and leave it stopped, an already-satisfied `WantedBy=` not being pulled again.

This is why `systemctl restart halow0-ibss.service` pulls attach with it.
It also means "I had to restart both" says nothing about a root cause:
the wiring forced it, whatever the underlying fault.

### `iw dev halow0 link` Looks Healthy and Nothing Works

IBSS forms a cell of one and reports success with no peer,
and `batman-adv` will likewise form a mesh of one that forwards nothing.

```sh
iw dev halow0 station dump   # the peer's MAC must be listed
batctl o                     # the other nodes must be listed
```

Those two are the real checks.

---

## The Mesh Is up but There Is No Internet

Work down the layers from the node:

```sh
ip -4 route show default    # expect: default via 192.168.12.1 dev bat0
ping -I bat0 192.168.12.1   # the router itself, over the mesh
batctl o                    # expect the router as an originator
batctl gwl                  # expect the router listed, with => on the selected one
resolvectl query one.one.one.one
```

| Symptom | Fault |
| --- | --- |
| no `default via 192.168.12.1` | Jetson: rerun `install_network_stack.sh` |
| `batctl o` empty | see [the mesh is down](#the-mesh-is-down) |
| `batctl gwl` empty | router: `gw_mode server` not set, or mesh not formed |
| router pings, internet does not | router: `ahwlan` -> `wan` forwarding, or `masq` |
| names fail, addresses work | see [names do not resolve](#names-do-not-resolve) |

### On the Bench: Names Resolve, Every Connection Fails `No route to host`

The mesh is down, Ethernet is up and healthy, and DNS answers --
the bench resolver is on-link, so lookups never touch the default route.
Every actual connection then dies with `No route to host`.
It is the inverse of a DNS fault, and it reads like one until the routes are compared:

```sh
ip -4 route show default
# default via 192.168.1.1 dev enx... proto dhcp metric 105     <- bench uplink, must win
# default via 192.168.12.1 dev bat0 proto static metric 4096   <- mesh, must be 4096
```

This was real: the v4 mesh gateway was once stamped as a plain `Gateway=` line,
which takes the kernel default metric 0 and outranks every DHCP route a bench can offer.
All IPv4 went into a peerless mesh while DNS kept answering.
The gateways are stamped as `[Route]` blocks with `Metric=4096` since,
so the mesh route carries traffic only when no other default remains.
A `bat0` default with metric 0 means an old install:
rerun `install_network_stack.sh`.

### `ping6` To a Public Resolver Fails on a Healthy Mesh

There is no IPv6 uplink.
`eth0` on the router takes a v4 DHCP lease and a link-local,
with no global v6 and no v6 default route,
so nothing on the mesh can reach a v6 destination off-site.
`masq6` is set on the `wan` zone but has nothing to masquerade onto.

Test the uplink over IPv4 (`ping -I bat0 1.1.1.1`).
`ping6 <node>.mesh` between Jetsons is the v6 test that should pass.

### A Node's ULA Does Not Answer, but Everything Else About It Works

Check what interface the address is on.
An address on a bridge *port* does not answer:
frames arriving on the port are handed to the bridge,
which delivers to the local stack only on the bridge's own MAC.
The address shows up in `ip addr`, the route shows up in `ip -6 route`,
and every packet is lost.

This was the router's mesh ULA,
which sat on `bat0` while `bat0` was a port of `br-ahwlan`.
It now lives on `br-ahwlan` itself, set through `network.ahwlan.ip6addr`.

```sh
ip -6 addr show br-ahwlan          # the address should be here
ip -d link show bat0 | grep bridge_slave
```

An IP on a bridge port is almost always a mistake, and it fails silently.

### `ping 8.8.8.8` Fails from a Jetson but `ping -I bat0` Works

The reply went out another interface.
Use `-I bat0` on any node that also has Ethernet or WiFi up,
or the test says nothing about the mesh.

---

## Names Do Not Resolve

```sh
resolvectl query wazza.local # resolved's own view
getent hosts wazza.local     # the NSS path, which is what applications see
getent hosts wazza.mesh      # the static roster
```

`getent` is the one that matters.
If `resolvectl` answers and `getent` does not,
the `resolve` NSS module is missing or `nsswitch.conf` is wrong, and mDNS is fine.

`.mesh` failing points at the roster or the address derivation.
`.local` failing points at mDNS, resolved or NSS.
Both failing points at the mesh itself.

Inside a container both fail even when the host resolves them,
because the container has its own `/etc/nsswitch.conf` and `/etc/hosts`
and no `systemd-resolved`.
See [HTTP_COMMS.md](HTTP_COMMS.md).

### A Node Was Added to the Roster and the Others Cannot See It

The roster is applied at install time.
Rerun `./install_network_stack.sh` on the other nodes.

The new node's IPv4 host octet is an explicit column, not derived from line
position, so inserting it anywhere in the file does not renumber any existing
node.
The only thing to get right is the octet itself: it must not already be taken
by another node in the roster, or the two nodes silently collide on the same
address.

---

## The Radio Behaves Oddly

### It Associates, Then Dies a Minute Later

Suspect a driver/firmware mismatch between the router and the Jetsons.

```sh
morse_cli -i wlan0 version   # on the router
morse_cli -i halow0 version  # on a Jetson
```

The Jetsons build `morse.ko` from source via DKMS;
the router runs whatever Morse shipped in its image,
so the two drift apart without anyone choosing that.

There is a report on Morse's forum of the MM8108 2.0.0 driver on OpenWrt 3.1.1
kernel-panicking shortly after two devices associate in IBSS mode, which the reporter
did not see on 1.17.9.
Morse could not reproduce it and it may not apply here, but "worked at association,
died a minute later" is distinctive enough to be worth recognising.
Align the router with the pair the Jetsons are known good on.

### The Radio Never Joins, and the Supplicant Does Not Complain

Check `s1g_prim_1mhz_chan_index`.
It must be less than the operating bandwidth, so at 1 MHz the only legal value is `0`.
The Morse fork defaults it to `3`,
which fails validation with `S1G Primary 1MHz index 3 invalid for operating BW 1`;
the network block is then rejected and the radio silently never joins.

Legal values are 0 at 1 MHz, 0-1 at 2, 0-3 at 4, 0-7 at 8.

### `iw dev` Reports a 5 GHz Channel

Expected.
The driver reports S1G channels as their 5 GHz equivalents,
so `channel 124 (5620 MHz), width: 20 MHz` for an S1G channel is not a misconfiguration.

### The Radio Does Not Appear at All

The card is driven over USB, and not every M.2 E-key slot wires up USB 2.0.
The driver cannot see a card that is only on PCIe lanes.

```sh
lsusb -d 325b: # expect 325b:8100
```

---

## Measurements Look Wrong

### Peering Succeeds and Every Data Frame Fails

Too much signal.
At 1 m the received level is around -8 dBm and the front end saturates,
which looks like a broken driver.
The oracle warns above -25 dBm.

Target -40 to -60 dBm, using different rooms or 30 dB inline attenuators,
and treat any RSSI taken at short range as meaningless for range planning.

### Throughput Numbers Do Not Reproduce

Check what else was on the air.
The router bridges `bat0` onto its LAN,
so every broadcast and multicast frame from a laptop on the APs floods into a 1 MHz
channel.
Get other clients off the APs for a measurement run,
and treat any figure taken with laptops attached as contaminated.

Also check peak channel busy before concluding anything about path loss.
A walk that ends in a built-up area can look like a range limit when it is contention.

### A Link Looks Fine in `iw station dump` and Carries Nothing

A station lingers in the dump well after it stops being reachable.
Ping is the authority.
This is why `walk` requires `LOSS_HOLD` consecutive failures
(default 5) before declaring the link down.

### Rows from Different Nodes Will Not Line Up

Clock sync.
The Jetsons have no RTC, and `soak` refuses to log
until `chronyc` reports the node synced.

```sh
chronyc sources -v   # '^*' marks the selected server; expect the router
chronyc tracking     # Last offset and RMS offset should be small
```

If the router itself has no uplink it will not serve time at all,
because busybox `sysntpd` refuses to serve time it does not have.
See [OPENWRT.md](OPENWRT.md) under Time for the `local stratum 10` fix.

---

## Messages That Look Alarming and Are Not

### `Section @forwarding[0] is disabled, ignoring section`

Printed on every `/etc/init.d/firewall restart` on the router.
It is GL.iNet's own disabled `lan` -> `wan` rule and predates everything here.
It appears immediately after whatever you just committed and reads like a report on it.
New sections land at the end, so the index in the message is not yours.

### `halow-mesh` Adds `wlan0` to `bat0` Several Times During One Boot

Expected.
`wlan0` is created and destroyed several times as netifd configures `radio2`
and `wpa_supplicant_s1g` joins the IBSS, and each destruction drops it from batman.
Every recreation fires the hotplug rule, so the script runs again and converges.

```text
15:02:27  halow-mesh: added wlan0 to bat0
15:02:28  halow-mesh: added wlan0 to bat0          <- again, after a recreation
15:02:29  halow-mesh: wlan0 is already a bat0 hard interface
```

### `batman_adv: bat0: No IGMP Querier present`

There is no querier on the bridge, so batman cannot narrow multicast and floods it.
This is a real cost on a 1 MHz link, and an open question.
See [OPENWRT.md](OPENWRT.md) under The Bridge.

### `batman_adv: bat0: Not using interface wlan0 (retrying later)`

Transient during boot, immediately before `Interface activated: wlan0`.
It is a fault only if no activation line follows.
