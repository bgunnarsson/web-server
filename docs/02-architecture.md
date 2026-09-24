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
and `Zone:Zone:Read` across all zones. Dokploy's Traefik does not use DNS-01
out of the box; `~/servset/dokploy/setup-letsencrypt-cloudflare.sh` switches it
and injects the token. Run it on the target before cutover, and again if a
Dokploy update ever recreates Traefik.

Certs are **not** migrated. Let the target issue its own — DNS-01 takes under a
minute per hostname and avoids copying private keys between machines.

## Who manages what

The Dokploy panel runs on `ncr` and deploys to robco over ssh. robco is one of
its remote servers, and the target becomes another. Moving a site is mostly a
Dokploy operation. This repo covers everything around it.

| | Managed by | Moves how |
|---|---|---|
| App code, build, containers | Dokploy | point the app at the new server, redeploy |
| Env vars and secrets of the apps | Dokploy | come along with the app |
| Domains and HTTP routers | Dokploy (container labels) | come along with the app |
| docker, swarm, `dokploy-network`, `dokploy-traefik` | Dokploy | installed when the server is added |
| DNS-01 cert resolver + `CF_DNS_API_TOKEN` | `~/servset/dokploy/setup-letsencrypt-cloudflare.sh` | re-run on the target |
| HTTPS routers (`websecure-routers.yml`) | `~/servset/dokploy/enable-https.sh` | re-run on the target |
| binbox + penpot data | nobody. A redeploy starts empty | `11-backup-volumes.sh` → `30-restore-volumes.sh` |
| Tunnel connector (`cloudflared.service`) | systemd, by hand | `50-cutover-dns.sh tunnel` |
| `design.bgunnarsson.dev` A record | Cloudflare DNS | `50-cutover-dns.sh tailnet` |
| Tailscale | by hand | `tailscale up` on the target |

### Why every script runs on robco

robco holds the data, the tunnel token (`/etc/cloudflared/env`, root-only) and
the tailnet route to the target, so the scripts run there and reach the target
over ssh. The snapshot streams from robco into the target's volumes, and the
token goes straight from robco's file into the target's. Neither is ever
copied anywhere else. The target needs no checkout of this repo.
