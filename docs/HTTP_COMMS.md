# HTTP(S) Between Nodes

Node-to-node traffic runs over the mesh's IPv6 ULA on `bat0`, one address per node,
derived from the radio MAC and stamped in by `install_network_stack.sh`.
The mesh also carries IPv4 now, on the router's LAN
(see `README.md`),
but no name resolves to those addresses: both naming mechanisms below are v6-only,
so everything here assumes IPv6.

Every node answers to two names by two independent mechanisms.
`<name>.mesh` is static, from `/etc/hosts`, generated from `etc/bat-hosts`.
`<name>.local` is mDNS, from `systemd-resolved`, advertised on `bat0`.

Prefer `.mesh` for anything that has to work.
It needs no daemon, no multicast, and no resolver beyond `/etc/hosts`.
`.local` keeps working when the roster is out of date,
since a node advertises itself whether or not anyone listed it.

Because the two are independent, whichever fails tells you what broke:
`.mesh` failing is the roster or the address derivation,
`.local` failing is mDNS/resolved/NSS, and both failing is the mesh itself.

That combination works, but three things sit between a working mesh
and a working request, and all three fail in ways that look like something else.
Read this before writing a service that talks to another node.

## 1. Bind to `::`, Not `0.0.0.0`

The likeliest failure by some margin.
A server left on its IPv4 default is unreachable across the mesh,
and the symptom is a connection refused on a name that resolved perfectly,
which looks like an application bug.
It is an addressing one.

```python
# WRONG -- IPv4 only, invisible on the mesh
app.run(host="0.0.0.0", port=8080)
uvicorn.run(app, host="0.0.0.0", port=8080)

# RIGHT -- dual-stack; accepts v6 (the mesh) and v4 (local/debug)
app.run(host="::", port=8080)
uvicorn.run(app, host="::", port=8080)
```

On Linux `::` is dual-stack, because `net.ipv6.bindv6only` defaults to `0`,
so binding it does not cost you local IPv4 testing.

For a raw socket the family has to change too,
since `AF_INET` cannot carry a v6 address:

```python
s = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
s.bind(("::", 8080))
```

Confirm on the node. `[::]` or `*` is what you want:

```sh
ss -tlnp | grep 8080
```

> `gunicorn` needs the brackets in its bind string: `--bind [::]:8080`.
> Without them it parses the colons as a host/port split and fails.

## 2. Resolution Only Works Through `getaddrinfo()`

`<hostname>.local` is answered by `systemd-resolved` over mDNS,
reached through the `resolve` entry in `/etc/nsswitch.conf`.
Anything that calls libc `getaddrinfo()` picks this up for free: `socket`,
`http.client`, `urllib`, `requests`, `httpx`,
and `aiohttp`'s default `ThreadedResolver`.
Ordinary Python needs no special handling.

Two things fall off that path.

A DNS client library that bypasses NSS is the first.
`aiodns`/`c-ares` talks to nameservers directly and never consults NSS,
so `.local` does not resolve.
This is opt-in for `aiohttp` (`AsyncResolver`), but if a dependency pulls it in,
name lookups start failing for that client only,
while `curl` on the same box works fine.

A container is the second.
It has its own `/etc/nsswitch.conf`, its own `/etc/hosts`, and no `systemd-resolved`,
so both `.local` and `.mesh` fail inside it even though the host resolves them.
`.mesh` is the easier of the two to repair, being a flat file:
bind-mounting the host's `/etc/hosts` read-only is enough,
where `.local` would need the whole resolved stack.
Host networking fixes both.

Verify the resolution path itself on a node, once the mesh is up:

```sh
resolvectl query wazza.local # resolved's own view
getent hosts wazza.local     # the NSS path, which is what Python will see
```

`getent` is the one that matters.
If `resolvectl` answers and `getent` does not,
the `resolve` NSS module is missing or `nsswitch.conf` is wrong, and mDNS is fine.

## 3. Choosing Between the Two Names

Both names resolve to the *same address*: two lookup mechanisms for one destination.
Trying one and falling back to the other buys nothing at the connection level:
if `.mesh` resolves and the request then fails,
`.local` resolves to the identical address and fails identically.
Nor is there automatic fallback between them; they are distinct FQDNs,
so a client that asks for one gets one lookup path,
and anything else has to be written by hand.

So use `.mesh` and do not write a fallback.
The only case a fallback addresses is a node that is up
but missing from this node's roster,
because the roster is regenerated at install time
and a newly added node has not been rolled out to its peers yet.
That is a deploy-state problem: fix it by rerunning the installer,
not by paying for a second lookup on every request forever.

The failure modes are asymmetric in a way that matters for any service
that polls its peers:

| Situation                | `.mesh`                              | `.local`                                      |
| ------------------------ | ------------------------------------ | --------------------------------------------- |
| Peer down or unreachable | resolves instantly, fails at connect | **blocks for seconds**, then fails to resolve |
| Peer missing from roster | fails to resolve                     | resolves, if the peer is up                   |

A polling loop over `.local` names therefore degrades badly the moment a node drops,
stalling on resolved's mDNS timeout before the connection is even attempted.

Resolve at startup where you can, caching the address and reconnecting against it,
and set explicit connect and read timeouts on everything.
The mesh is multi-hop and lossy;
default timeouts of "never" will hang a service on a link that is merely slow.

```python
# Timeouts are not optional on a mesh link.
requests.get("http://wazza.mesh:8080/health", timeout=(3.05, 10))
```

## 4. HTTPS Needs an Internal CA

No public CA will issue a certificate for a `.local` name,
so TLS between nodes means self-signed certificates or a small internal CA,
with every `.local` name a node is reached by listed in the SAN,
and the CA installed into each node's trust store
(`/usr/local/share/ca-certificates/` plus `update-ca-certificates` on Debian).
Python reads the system store through `certifi` only for some libraries;
`requests` uses `certifi` by default and will not see the system CA
unless pointed at it:

```python
requests.get("https://wazza.local:8080", verify="/path/to/mesh-ca.crt")
```

Setting `REQUESTS_CA_BUNDLE` in the service environment avoids threading
that through every call site.

> Consider whether TLS is the right layer here at all.
> The mesh can be encrypted below HTTP, by RSN-IBSS
> (see `etc/wpa_supplicant/wpa_supplicant-halow0.conf`)
> or WireGuard over `bat0`,
> which gives confidentiality for every protocol at once
> and no certificate distribution problem across field nodes.
> Plain HTTP over an encrypted link is often the better trade here.

## 5. Literal Addresses Need Brackets

Rarely needed, since the point of mDNS is not to type addresses, but when debugging:

```sh
curl 'http://[fdc7:37f3:e24a:0:ebf:74ff:fe00:5bc8]:8080/'
```

The brackets belong to the URL syntax, so they are needed with or without the quotes.
`ping6 -I bat0 ff02::1` is the better first probe,
since it finds mesh peers with no names, no ULA, and no routing.

## Checklist

On a node, in this order.
Each step's failure points at a different layer:

```sh
ping6 -I bat0 ff02::1           # peers reachable at all?
getent hosts wazza.mesh         # static names -- the roster
getent hosts wazza.local        # mDNS names -- resolved and NSS
ss -tlnp | grep 8080            # bound to [::] and not 0.0.0.0?
curl -v http://wazza.mesh:8080/ # the actual request
```
