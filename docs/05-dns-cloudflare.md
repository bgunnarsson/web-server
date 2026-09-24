# Cloudflare: tunnels, DNS, and the one hostname that must stay private

Account `03403c8d64890f093172d1cfb128af97`. Ten zones:
`bgunnarsson.com`, `bgunnarsson.dev`, `bincms.dev`, `binflix.is`, `binman.is`,
`binsby.com`, `bintiny.com`, `binvim.dev`, `galdur.dev`, `skateboarding.is`.

Only six carry sites that live on robco.

## The tunnel that matters

**`a1b9673e-38ca-4738-947c-ebf466fb4cec`**, named `robco`. Its connector is the
`cloudflared` systemd service on this host. Live ingress, read from the API on
2026-09-24:

```
bgunnarsson.com        -> http://localhost:80
bincms.dev             -> http://localhost:80
binman.is              -> http://localhost:80
binsby.com             -> http://localhost:80
binvim.dev             -> http://localhost:80
galdur.dev             -> http://localhost:80
www.* (same six)       -> http://localhost:80
(fallback)             -> http_status:404
```

Twelve hostnames, all to local Traefik, plus a 404 catch-all.

Because every rule targets `localhost`, the ingress config **does not change**
during the migration. `localhost` simply means a different machine once the
connector moves. `scripts/50-cutover-dns.sh tunnel` does exactly that and
nothing else.

### Other tunnels on the account — leave them alone

- **`5912c888-4551-474f-9e86-48a22f0f9ece`** (`dokploy`) — connector runs on
  `ncr`. Serves `bgunnarsson.dev` → a Dokploy panel on ncr, and proxies the six
  zones to `http://robco:80` over the tailnet as a second path. DNS does not
  route to those rules today, but they will point at a dev box once robco is
  retired. `50-cutover-dns.sh check` lists them. Repoint or remove them in the
  dashboard after cutover. **If you pick `ncr` as the target**, point them at
  `http://localhost:80` instead.
- **`804d3d46-…`** — belongs to a different tailnet box, used by
  `binflix.is`. Dead and not fixable from here.

## design.bgunnarsson.dev — the exception

This is the one hostname that is **not** on a tunnel and must never be put on
one.

| | |
|---|---|
| Record | `A design.bgunnarsson.dev -> 100.87.155.125` |
| Proxy | **DNS-only (grey cloud)** |
| Reachable from | the tailnet only |
| Gate | the tailnet itself — penpot has no other authentication in front of it |

It was made tailnet-only on 2026-08-07, and its Cloudflare Access app was
removed at the same time. Making the A record proxied, or adding the hostname
to any tunnel's ingress, puts a private design tool on the public internet.

`scripts/50-cutover-dns.sh tailnet` repoints this record to the target's
tailnet IP with `proxied:false` hard-coded.

### The automation footgun

`~/servset/cloudflare-tunnel/add-hostnames.sh` and `point-dns-to-tunnel.sh`
build their hostname list from **live Traefik labels**. Traefik serves
`design.bgunnarsson.dev`, so both scripts would happily publish it. They are
guarded by `cloudflare-tunnel/tunnel-exclude.txt`, which lists it.

**The runbook copies all of `~/servset` to the target, so `tunnel-exclude.txt`
travels with the scripts. Keep it that way.** If you ever copy only part of it,
carry the exclude file too.

## DNS during cutover

For the six public sites: **nothing changes.** The CNAMEs already point at
`<tunnel-id>.cfargotunnel.com`, proxied. Moving the connector is the whole
cutover, and it takes effect in seconds with no DNS propagation to wait for.

For `design.bgunnarsson.dev`: one A record, TTL 60, applied by the `tailnet`
sub-command.

## Checking the state

```bash
scripts/50-cutover-dns.sh check
```

Prints the ingress rules, the live connectors, and the tailnet record.

**Watch the connector count.** Two connectors on one tunnel means Cloudflare is
load-balancing between robco and the target, so requests land on whichever
machine answers — the classic way to get a half-migrated site that works
intermittently and is maddening to debug. `60-verify.sh` fails if the count is
anything but 1.

## SSL/TLS mode

Each zone is set to **Full (strict)**. That governs Cloudflare↔origin for
direct connections; tunnel traffic uses the ingress rule's scheme instead
(`http://localhost:80`). Leave the zone setting as it is.
