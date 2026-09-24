# How a request reaches a site

## Public sites (six of the seven)

```
browser
  │  https://galdur.dev
  ▼
Cloudflare edge          TLS terminates here. DNS is a PROXIED CNAME to
  │                      a1b9673e-38ca-4738-947c-ebf466fb4cec.cfargotunnel.com
  ▼
tunnel "robco"           Cloudflare routes by hostname using the tunnel's
  │                      ingress rules, stored in Cloudflare, not on the host.
  ▼
cloudflared (systemd)    Outbound connection, dialled from the host. This is
  │  http://localhost:80 the only reason the sites work behind CGNAT.
  ▼
Traefik :80              Routes by Host() rule from container labels.
  │
  ▼
site container
```

The host is never contacted from outside. It dials out, and Cloudflare hands it
work over that connection. **Migrating the public sites is therefore not a DNS
change** — it is moving which machine runs `cloudflared` with that tunnel's
token. DNS keeps pointing at the tunnel throughout.

### Why HTTP at the origin, and why not to "fix" it

The tunnel's ingress service is `http://localhost:80`. Traffic between
cloudflared and Traefik is plain HTTP over loopback on the same machine, which
is fine — it never touches a network.

Do not add a global HTTP→HTTPS redirect on the `web` entrypoint. The browser is
already on HTTPS to Cloudflare; a 301 from the origin sends it back through
Cloudflare to the same place, and the site becomes a redirect loop. The
`redirect-to-https` middleware exists in the dynamic config but is deliberately
attached to nothing.

## The tailnet-only site

```
browser on the tailnet
  │  https://design.bgunnarsson.dev
  ▼
DNS-only A record  ──►  100.87.155.125   (the host's Tailscale IP, grey cloud)
  │
  ▼
Traefik :443       Real Let's Encrypt cert, issued over DNS-01.
  │
  ▼
penpot-frontend:8080
```

No Cloudflare proxy, no tunnel. The tailnet **is** the access control — penpot
has no other gate in front of it. This is why the A record must stay
DNS-only: proxying it, or adding the hostname to the tunnel, publishes a
private design tool to the internet.

## Certificates

Traefik's `letsencrypt` resolver uses the **DNS-01** challenge via the
Cloudflare API, not HTTP-01. That choice is load-bearing twice over:

1. Public hostnames sit behind Cloudflare's proxy with Always Use HTTPS, which
   breaks HTTP-01's plain-HTTP validation request.
2. `design.bgunnarsson.dev` is not publicly reachable at all, so HTTP-01 could
   never validate it — but DNS-01 proves ownership through the API and works
   regardless.

This needs `CF_DNS_API_TOKEN` on the Traefik container, with `Zone:DNS:Edit`
and `Zone:Zone:Read` across all zones. Certificates land in
`acme.json`, which must be mode `0600` or Traefik refuses to start.

Certs are **not** migrated. Let the target issue its own — DNS-01 takes under a
minute per hostname and avoids copying private keys between machines.

## Why this drops Dokploy

Dokploy is not running on robco any more. Its control plane is gone; what
remains is `/etc/dokploy/compose/<name>-<hash>/code/` holding seven checked-out
repos and seven generated `docker-compose.yml` files, which plain
`docker compose` is running.

Rebuilding that on the target as Dokploy would mean reinstalling a control
plane that is not currently in use, recreating a single-node swarm that exists
only to satisfy it, and accepting its generated artifacts:

- router names like `robco-binbox-odjv6q-14-web`, carrying a dead hostname and
  a random suffix
- an ACME contact of `test@localhost.com`, which receives no expiry warnings
- `api.insecure: true`, an unauthenticated Traefik dashboard on :8080
- short-lived GitHub App tokens written into every repo's `.git/config`, all of
  them long expired and still sitting on disk

The stacks in `stacks/` are the same services with those problems removed:
readable names, both HTTP and HTTPS routers declared in the compose file,
secrets in gitignored `.env` files, and a shared `proxy` network instead of
`dokploy-network`.

**The trade-off, stated plainly:** you lose Dokploy's web UI and its
git-push-to-deploy. Redeploying becomes `scripts/40-deploy-stacks.sh <name>`,
which fetches the repo and rebuilds. If you want a panel back, install Dokploy
on the target and import these compose files — the stacks are ordinary compose
and do not depend on anything here.

## What changes between the two machines

| | robco (today) | target (after) |
|---|---|---|
| Orchestration | compose, Dokploy leftovers | compose |
| Docker swarm | single-node, unused | none |
| Shared network | `dokploy-network` (overlay) | `proxy` (bridge) |
| Stack location | `/etc/dokploy/compose/<name>-<hash>/code` | `$TARGET_ROOT/stacks/<name>` |
| Traefik config | `/etc/dokploy/traefik/` | `$TARGET_ROOT/traefik/` |
| Router names | `robco-binbox-odjv6q-14-web` | `binbox` |
| Traefik dashboard | `api.insecure: true` | disabled |
| ACME email | `test@localhost.com` | your address |
| ssh port | 2222 | 22 |
| Tunnel | unchanged — same tunnel, same ingress, different connector host | |
