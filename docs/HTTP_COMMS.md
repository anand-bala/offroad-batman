# HTTP(S) Between Nodes

The mesh carries one address family: an IPv6 ULA on `bat0`, per node,
derived from the radio MAC and stamped in by `install_network_stack.sh`.
There is no IPv4 anywhere on the mesh.

Every node answers to two names, by two independent mechanisms:

| Name           | Mechanism | Source                                       |
| -------------- | --------- | -------------------------------------------- |
| `<name>.mesh`  | static    | `/etc/hosts`, generated from `etc/bat-hosts` |
| `<name>.local` | mDNS      | `systemd-resolved`, advertised on `bat0`     |

Prefer `.mesh` for anything that has to work.
It needs no daemon, no multicast, and no resolver beyond `/etc/hosts`,
which every language and every container reads.
`.local` is the one that keeps working when the roster is out-of-date,
since a node advertises itself whether or not anyone listed it.

Because the two are independent, the one which fails will tell you what broke:
`.mesh` failing is the roster or the address derivation,
`.local` failing is mDNS/resolved/NSS,
and both failing is the mesh itself rather than naming.

That combination works, but three things sit between a working mesh
and a working request, and all three fail in ways that look like something else.
Read this before writing a service that talks to another node.

## 1. Bind to `::`, Not `0.0.0.0`

The single likeliest failure.
A server left on its IPv4 default is unreachable across the mesh,
and the symptom is a **connection refused** on a name that resolved perfectly,
which reads like an application bug rather than an addressing one.

```python
# WRONG -- IPv4 only, invisible on the mesh
app.run(host="0.0.0.0", port=8080)
uvicorn.run(app, host="0.0.0.0", port=8080)

# RIGHT -- dual-stack; accepts v6 (the mesh) and v4 (local/debug)
app.run(host="::", port=8080)
uvicorn.run(app, host="::", port=8080)
```

`::` is dual-stack rather than v6-only on Linux,
because `net.ipv6.bindv6only` defaults to `0`,
so binding it does not cost you local IPv4 testing.

For a raw socket, the family has to change too -- `AF_INET` cannot carry a v6 address:

```python
s = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
s.bind(("::", 8080))
```

Confirm on the node.
You want `[::]` or `*`, never `0.0.0.0`:

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
For ordinary Python this needs no special handling at all.

Two ways to fall off that path:

**A DNS client library that bypasses NSS.**
`aiodns`/`c-ares` talks to nameservers directly and never consults NSS,
so `.local` does not resolve.
This is opt-in for `aiohttp` (`AsyncResolver`),
not the default -- but if a dependency pulls it in,
name lookups start failing for that client only,
while `curl` on the same box works fine.

**A container.**
A container has its own `/etc/nsswitch.conf`, its own `/etc/hosts`,
and no `systemd-resolved`,
so **both** `.local` and `.mesh` fail inside it even though the host resolves them.
`.mesh` is the easier of the two to repair -- it is a flat file,
so bind-mounting the host's `/etc/hosts` read-only is enough,
where `.local` would need the whole resolved stack.
Host networking fixes both.

Verify the resolution path itself on a node, once the mesh is up:

```sh
resolvectl query wazza.local # resolved's own view
getent hosts wazza.local     # the NSS path -- what Python will see
```

`getent` is the one that matters.
If `resolvectl` answers and `getent` does not,
the `resolve` NSS module is missing or `nsswitch.conf` is wrong, not mDNS.

## 3. Choosing Between the Two Names

Both names resolve to the *same address*.
They are two lookup mechanisms for one destination, not two routes to it,
so trying one and falling back to the other buys nothing at the connection level:
if `.mesh` resolves and the request then fails,
`.local` resolves to the identical address and fails identically.

There is also no automatic fallback between them.
They are distinct FQDNs, so a client that asks for one gets one lookup path.
Anything else has to be written by hand.

**Use `.mesh`, and do not write a fallback.**
Resolution failure and reachability failure are different problems,
and the fallback only addresses a case that is not a runtime case at all:
a node that is up but missing from this node's roster,
because the roster is regenerated at install time
and a newly added node has not been rolled out to its peers yet.
That is a deploy-state problem.
Fix it by rerunning the installer,
not by paying for a second lookup on every request forever.

The failure modes are also asymmetric in a way that matters for any service
that polls its peers:

| Situation                | `.mesh`                              | `.local`                                      |
| ------------------------ | ------------------------------------ | --------------------------------------------- |
| Peer down or unreachable | resolves instantly, fails at connect | **blocks for seconds**, then fails to resolve |
| Peer missing from roster | fails to resolve                     | resolves, if the peer is up                   |

A `.local` name for a dead peer stalls on resolved's mDNS timeout *before* the
connection is even attempted, so a polling loop over `.local` names degrades badly the
moment a node drops.
`.mesh` fails fast at the layer that actually knows something is wrong.

Resolve at startup rather than per request where you can -- cache the address,
reconnect against the address -- and set explicit connect
and read timeouts on everything.
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
`requests` uses `certifi` by default and will **not** see the system CA
unless pointed at it:

```python
requests.get("https://wazza.local:8080", verify="/path/to/mesh-ca.crt")
```

Setting `REQUESTS_CA_BUNDLE` in the service environment avoids threading
that through every call site.

> Consider whether TLS is the right layer here at all.
> The mesh can be encrypted below HTTP -- RSN-IBSS
> (see `etc/wpa_supplicant/wpa_supplicant-halow0.conf`)
> or WireGuard over `bat0` -- which gives confidentiality for every protocol at once
> and no certificate distribution problem across field nodes.
> Plain HTTP over an encrypted link is often the better trade here.

## 5. Literal Addresses Need Brackets

Rarely needed, since the point of mDNS is not to type addresses, but when debugging:

```sh
curl 'http://[fdc7:37f3:e24a:0:ebf:74ff:fe00:5bc8]:8080/'
```

The brackets are part of the URL syntax, not the shell quoting.
`ping6 -I bat0 ff02::1` is the better first probe -- it finds mesh peers with no names,
no ULA, and no routing.

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
