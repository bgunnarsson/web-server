# What robco runs today

Captured 2026-09-24 from the live host. Everything below was read off the
running system, not from memory or documentation.

## The machine

| | |
|---|---|
| Hostname | `robco` |
| Hardware | Lenovo ThinkCentre M910q (desktop, x86-64) |
| OS | Arch Linux, kernel 6.19.9 |
| LAN IP | `192.168.1.31` |
| Tailscale IP | `100.87.155.125` |
| Public IP | `46.182.187.155` — **carrier-grade NAT (Nova)**, shared with three other boxes |

The public IP is CGNAT, so **no inbound port forwarding is possible**. Nothing
reaches this machine from the internet directly. All public traffic arrives
through an outbound Cloudflare tunnel. Any replacement host has the same
freedom: it does not need a public IP either, as long as it can dial out.

## Websites

Seven application stacks, thirteen hostnames.

| Stack | Hostnames | Port | Build | Persistent data |
|---|---|---|---|---|
| bgunnarsson-com | bgunnarsson.com, www | 80 | `nginx:alpine` + custom `nginx.conf` | — |
| bincms | bincms.dev, www | 80 | `nginx:alpine`, repo root as-is | — |
| binman | binman.is, www | 80 | `nginx:alpine`, repo root as-is | — |
| binsby | binsby.com, www | 80 | `nginx:alpine`, repo root as-is | — |
| binvim | binvim.dev, www | 80 | vite build (node:22) → nginx | — |
| binbox | galdur.dev, www | 8787 | node:24-bookworm, pnpm, native `better-sqlite3` | **1.3 GB** |
| penpot | design.bgunnarsson.dev | 8080 | upstream images, pinned 2.17.0 | **74 MB** |

Six are public. `design.bgunnarsson.dev` is **tailnet-only** and must stay that
way — see [05-dns-cloudflare.md](05-dns-cloudflare.md).

### Source repositories

All under the `bgunnarsson` GitHub account:
`bgunnarsson.com`, `bincms-web`, `binman-web`, `binsby-web`, `binvim-web`,
`binbox`. Penpot needs no repo — it runs upstream images.

### Persistent data

| Volume | Size | Contents |
|---|---|---|
| `robco-binbox-odjv6q_binbox-data` | 1.3 GB | `binbox.db` (30 MB), `catalog.db` (679 MB), `images/` (598 MB, 6404 files) |
| `robco-design-llggv8_penpot_postgres_v15` | 69 MB | PostgreSQL 15.17 |
| `robco-design-llggv8_penpot_assets` | 4.6 MB | uploaded files |

`catalog.db` is a downloaded card catalogue and `BINBOX_CATALOG_AUTOSYNC=on`
rebuilds it, so in the worst case it can be regenerated rather than copied. The
other two cannot.

## Infrastructure

| Service | How it runs | Purpose |
|---|---|---|
| `cloudflared.service` | systemd, `EnvironmentFile=/etc/cloudflared/env` | outbound tunnel, token mode |
| `dokploy-traefik` | plain container, `traefik:v3.6.7` | reverse proxy on :80/:443 |
| `docker.service` | systemd | single-node **swarm** (leader) |
| `tailscaled.service` | systemd | private network |
| `sshd.service` | systemd, **port 2222** | not 22 — see below |

### Dokploy runs on ncr, not here

robco is a **remote server** of the Dokploy panel on `ncr`. The panel is
reached at `bgunnarsson.dev` through ncr's `dokploy` tunnel. It SSHes into
robco on :2222 and runs everything here: seven compose projects under
`/etc/dokploy/compose/<app>-<hash>/`, plus `dokploy-traefik`. That is why
there is no panel container and `docker service ls` is empty. The single-node
swarm is part of Dokploy's remote-server setup.

So moving the sites means pointing each Dokploy app at the new server and
redeploying. Only what Dokploy does not manage needs this repo: the data, the
tunnel connector, the tailnet hostname and the Traefik edits below.

### Traefik was changed by hand

Dokploy generated robco's Traefik; `~/servset/dokploy/` changed it on
2026-06-16. None of this happens on a new Dokploy server by itself:

| Change | Made by | Why it matters |
|---|---|---|
| ACME `httpChallenge` → `dnsChallenge` (Cloudflare) in `/etc/dokploy/traefik/traefik.yml` | `setup-letsencrypt-cloudflare.sh` | HTTP-01 cannot work behind Cloudflare's proxy or for a tailnet-only host |
| `CF_DNS_API_TOKEN` in the `dokploy-traefik` container's env | same | DNS-01 needs it |
| `dynamic/websecure-routers.yml`, an HTTPS copy of every app's HTTP router | `enable-https.sh` | Dokploy only made HTTP routers. **penpot's only HTTPS route** comes from this file |

Re-run both scripts on the target (runbook phase 2). Still as Dokploy left
them, and worth fixing in its Traefik settings some time: `api.insecure: true`
(unauthenticated dashboard on :8080) and an ACME email of `test@localhost.com`.

### sshd on port 2222

`/etc/ssh/sshd_config` sets `Port 2222`, with `PasswordAuthentication no` and
`PermitRootLogin no`. The Dokploy panel on ncr connects on that port. The
scripts here run on robco itself, so they never ssh to it.

## Secrets in use

Enumerated with their locations in [03-secrets.md](03-secrets.md).

## Deliberately out of scope

- **Email.** All these zones have MX records at `1984.is`, an inherited
  arrangement with no server-side access. Nothing here touches MX or SRV
  records, and nothing should. Deleting one would break mail irreversibly.
- **Other hosts.** `ncr`, `vaultec` and `enclave` share the LAN and tailnet.
  `binflix.is` is served from `vaultec`, not here. `bgunnarsson.dev`'s apex
  points at a second tunnel whose connector runs on `ncr`. None of that moves
  with these websites.
