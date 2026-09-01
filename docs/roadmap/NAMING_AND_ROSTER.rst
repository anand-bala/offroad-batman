========================================================
Retiring the Roster: Naming Without etc/bat-hosts
========================================================

Context
=======

A HaLow chip was replaced after a field crash. The new chip carried a new
MAC, and because node identity and every node's address were derived from
MACs held in ``etc/bat-hosts``, that one replacement had to be propagated
to every node in the fleet before the mesh worked again.

Three changes have landed against that problem:

1. The IPv6 default route is gone. It was EUI-64 derived from the
   gateway's roster MAC and pointed at a router with no v6 uplink to
   forward onto.
2. Each roster entry carries an explicit IPv4 host octet. The octet used
   to come from a node's line position, so inserting a node renumbered
   every node below it.
3. Node identity is hostname-led. ``node_name`` prefers the system
   hostname when that hostname is already a roster name, so a replacement
   chip no longer changes who a node is.

What remains is written down below.

----

1. The ``.mesh`` block in /etc/hosts
====================================

This is the last copy of *other* nodes' derived state on every node.
``merge_hosts`` (``halow-lib.sh``) writes one ``<name>.mesh`` entry per
roster node into ``/etc/hosts`` at install time, each address EUI-64
derived from that node's roster MAC. One chip replacement invalidates the
block on every node at once, which is the viral update this whole effort
is about.

Deleting it is a two-line change. It has not been made because mDNS is
not a free substitute for it. ``docs/HTTP_COMMS.md`` records the
asymmetry: against a peer that is **down**, ``.mesh`` resolves instantly
out of the flat file and fails at connect, while ``.local`` blocks for
seconds on systemd-resolved's mDNS timeout before a connection is
attempted. The jobs stack in ``src/offroad_batman/jobs/`` polls its
peers, so that cost would be paid per poll, per down peer.

**Before deciding, measure.** On the 1 MHz link, with a peer powered
off::

    time getent hosts <peer>.local
    time getent hosts <peer>.mesh

If the ``.local`` penalty is small enough to absorb, drop the block and
rewrite the naming guidance in ``docs/HTTP_COMMS.md`` (which currently
says to prefer ``.mesh`` and not to write a fallback) along with
``docs/MANET_JOBS.md``, whose example URLs are all ``.mesh``.

An intermediate option, if the penalty is real: keep a ``.mesh`` entry
for the node *itself* and drop only the peer entries. That removes every
viral copy while leaving the name namespace and self-reference intact.

----

2. What the roster is still load-bearing for
============================================

After the three changes above, ``etc/bat-hosts`` is still consulted for:

- **First boot.** A newly imaged node has a factory hostname that is not
  a roster name, so ``node_name`` falls through to the MAC lookup to
  learn what it is called. A new node therefore still needs its MAC in
  the roster before its first install. A *running* node does not.
- **The IPv4 octet**, now an explicit column rather than a derivation,
  which is a table entry rather than a derived copy.
- **The peer ``.mesh`` entries**, item 1 above.
- **The oracle**, which runs on a laptop that never ran the installer and
  reaches nodes by derived address (``node_target`` in ``halow-lib.sh``).
  A stale roster there is one edit on one machine, so this is deliberate
  and is not viral.
- **batctl cosmetics**, the roster's original purpose: names instead of
  hex in ``batctl o`` and ``batctl n``.

----

3. Latent: the gateway name comparison
======================================

``install_network_stack.sh`` gates the default route and the chrony time
source on ``[[ -n $GATEWAY_NAME && $GATEWAY_NAME != "$NODE_NAME" ]]`` --
a string comparison. If a node's hostname ever differs from the roster
name of the gateway it is meant to be, the guard fails to fire and the
node installs a route and a time source pointing at itself.

This is latent, not live: the gateway is the OpenWrt router, which never
runs this installer. It becomes live the moment a Jetson is made the
gateway. ``is_self`` (``halow-lib.sh``) already does this correctly, by
MAC or hostname; the installer should use it rather than comparing
strings.

----

4. Open question: should chrony follow the v4 gateway?
======================================================

``GATEWAY_ADDR`` survives only as the chrony time source, and it is the
last address in the system still EUI-64 derived from a roster MAC. If the
router's own radio is ever replaced, every node loses its time source
until re-stamped -- the original viral failure, in the one place it still
exists.

Pointing chrony at ``MESH_V4_GATEWAY`` instead would remove the last
roster MAC derivation entirely. That address is a written-down literal
(``192.168.12.1``) belonging to ``br-ahwlan``, which UCI sets. The cost
is that clock sync becomes IPv4-only, so a node with no valid octet
column would have no time source, and ``batman_oracle.sh soak`` refuses
to log without sync.

Not done because it trades one dependency for another and the tradeoff
has not been argued through.

----

5. Unexplored: discovering peers from batman-adv directly
=========================================================

Rather than any roster, ask batman-adv who its neighbours are.

What the vendored source says (``drivers/batman/batman-adv``): there is
no ``debugfs.c`` in this tree, so the old
``/sys/kernel/debug/batman_adv/*/originators`` text files do not exist
and generic netlink is the only interface. ``BATADV_CMD_GET_NEIGHBORS``
and ``BATADV_CMD_GET_ORIGINATORS`` both carry
``.flags = GENL_UNS_ADMIN_PERM`` in ``netlink.c``, so both need
``CAP_NET_ADMIN``. That is a capability rather than root as such: a
Python client could hold it ambiently through a systemd unit
(``AmbientCapabilities=CAP_NET_ADMIN``) with no sudo rule and no shelling
out to ``batctl``. ``BATADV_CMD_GET_MESH``, ``GET_HARDIF`` and
``GET_VLAN`` are ungated, and none of them enumerate peers.

This does not solve naming on its own. Netlink returns link-layer MACs,
which is the same fact the roster already holds; it yields a live peer
list with no hostnames. Closing that gap would mean deriving each
discovered peer's IPv6 link-local from its MAC and asking that address
what it calls itself.

**Unverified, and the thing to check first:** neighbours are reported per
*hard* interface (``batadv_hardif_neigh_dump``), meaning ``wlan0``, while
the link-local you would connect to lives on ``bat0``. Whether
batman-adv gives ``bat0`` the primary hard interface's MAC decides
whether that derivation is correct at all. Read ``hard-interface.c`` and
``mesh-interface.c`` before building anything on this.

----

6. Unverified: link-local scope through mDNS
============================================

Relevant only if static addressing is ever replaced by DHCP or
link-local-only addressing.

``25-bat0.network`` sets ``LinkLocalAddressing=ipv6``, so every node
always holds an ``fe80::`` address on ``bat0`` with no router involved.
IPv4 has no equivalent there: DHCP would fail with no server, and that
setting does not enable IPv4 link-local. A routerless pair would
therefore be IPv6-link-local-only.

mDNS discovery itself is peer-to-peer and needs no router. What is not
established is whether a ``.local`` lookup resolving to a link-local
address carries its scope index through ``getaddrinfo()`` to the caller.
``README.md`` documents the manual form with an explicit scope
(``ssh <node>@fe80::XXXX%<laptop-eth>``), which suggests the scope is
load-bearing in practice.

Two consumers would break on a bare unscoped link-local regardless:
``batman_oracle.sh`` binds iperf3 to the mesh address, and
``node_target`` returns addresses unbracketed and unscoped.
