# Travel Router (OpenWrt) as Mesh Gateway

The GL-iNet-class travel router ships configured as an 802.11s mesh point. 802.11s
and IBSS cannot interoperate,
so once the Jetsons run IBSS + batman-adv the router has to move to IBSS too,
or it is simply unreachable from the fleet.

Its job in the deployed network is **gateway**:
it carries the Starlink uplink and announces itself through batman-adv,
so any Jetson reaches the internet from wherever it is, over however many hops.

Do this only after the Jetson-to-Jetson IBSS gate passes (see `README.md`).
Until then the router is a working debug bridge and is worth leaving alone.

> Everything below is derived from the Gateworks GW16167 wiki
> and standard OpenWrt practice.
> It has not been run against the router.
> Expect to adjust, and keep console/LAN access -- the wireless reconfiguration will
> drop you.

## 1. Take UCI off the HaLow Radio

Gateworks explicitly recommends this:
the UCI layer does not yet understand the S1G features,
so drive the radio with the `_s1g` tools directly and leave UCI to manage bridges,
firewall and the uplink.

```sh
uci set wireless.radio0.disabled='1'
uci commit wireless
wifi reload
```

LuCI still manages everything else; the HaLow radio just stops being its business.

## 2. Packages

```sh
opkg update
opkg install kmod-batman-adv batctl
```

The Morse packages should already be present
(`wpa_supplicant_s1g`, `morse_cli`, `mm8108-firmware`, `kmod-mm8108_usb`).
If not, they are in the Gateworks package feed.

Note `wifi interfaces do not appear in /sys/class/net` on OpenWrt -- use `iw dev` to
enumerate.

## 3. IBSS Interface

Parameters must match the Jetsons **exactly** -- SSID, channel, op_class, country,
beacon interval.
Only the IP differs.

```sh
iw phy phy0 interface add wlan0 type ibss
ip link set wlan0 up

cat >/etc/wpa_supplicant_s1g_ibss.conf <<'EOF'
country=US
ctrl_interface=/var/run/wpa_supplicant_s1g
ap_scan=2

network={
        ssid="HaLow-IBSS"
        mode=1
        channel=33
        op_class=68
        country="US"
        beacon_int=1000
        key_mgmt=NONE
}
EOF

wpa_supplicant_s1g -i wlan0 -c /etc/wpa_supplicant_s1g_ibss.conf -B
```

Channel/op_class per the Gateworks table;
the frequency mapping is `freq_MHz = 902 + 0.5 * channel`:

| Bandwidth | Channel | op_class | Centre |
| --- | --- | --- | --- |
| 1 MHz | 33 | 68 | 918.5 MHz |
| 2 MHz | 10 | 69 | 907 MHz |
| 4 MHz | 40 | 70 | 922 MHz |
| 8 MHz | 28 | 71 | 916 MHz |
| 8 MHz | 12 | 71 | 908 MHz (router's setting) |

The radio reports S1G channels as their 5 GHz equivalents,
so `iw dev` showing `channel 100 (5500 MHz), width: 160 MHz`
for an 8 MHz S1G channel is expected.

For encrypted IBSS, replace `key_mgmt=NONE` with the RSN block from `halow-ibss.sh`
and use the same PSK fleet-wide.
Note this is RSN-IBSS, not SAE -- see the security notes in `README.md`.

## 4. Batman-Adv on Top

```sh
modprobe batman-adv
batctl meshif bat0 interface add wlan0
ip link set bat0 up
ip addr add 192.168.50.254/24 dev bat0
```

`wlan0` carries only batman traffic from here on -- do not put an IP on it
and do not bridge it directly.
Bridge `bat0` if you need to.

## 5. Gateway Announcement

On the router:

```sh
batctl meshif bat0 gw_mode server
```

On each Jetson:

```sh
batctl meshif bat0 gw_mode client
```

batman-adv then elects the gateway and the Jetsons route out through it automatically.
This replaces any hand-configured default routes;
it is the reason to run batman-adv rather than static routing over IBSS.

Bridging `bat0` to the WAN/Starlink side
and the firewall zones remain ordinary OpenWrt work and can stay in UCI/LuCI.

## 6. Verify

```sh
iw dev wlan0 station dump      # IBSS peers, should list the Jetsons
batctl meshif bat0 neighbors   # direct batman neighbours
batctl meshif bat0 originators # every node, with next hop and link quality
batctl meshif bat0 gwl         # gateway list
morse_cli -i wlan0 stats       # PHY-level sanity, incl. temperature
```

`originators` is the useful one in the field:
it shows multi-hop paths forming and re-forming as nodes move,
which is the whole point of the exercise.

## 7. Persistence

The commands above do not survive a reboot.
Once the configuration is settled,
put steps 3-5 in `/etc/rc.local` or a procd init script.
Deliberately leave this until the parameters stop changing -- a half-working config
that auto-starts on boot is harder to debug than one you invoke by hand.

## Open Questions

- Whether the router's Morse driver build advertises IBSS.
  Check with `iw phy phy0 info | grep -A10 'Supported interface modes'`
  before anything else; if `IBSS` is absent the whole approach needs rethinking on this
  device.
- Whether to stay at 8 MHz.
  It is the current setting and the worst one for range;
  1 or 2 MHz buys roughly 3 dB of sensitivity per halving.
  This is a fleet-wide decision -- every node must match.
