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

### Two things that are not what they look like

**Dokploy is already gone.** `/etc/dokploy/` and the `robco-*-<hash>` project
names are its leftovers, but the Dokploy control plane is not running —
`docker service ls` is empty and there is no panel container. What actually
runs is seven ordinary `docker compose` projects plus a Traefik container.
There is nothing to migrate about Dokploy itself. This repo therefore rebuilds
the sites as plain compose stacks; see
[02-architecture.md](02-architecture.md#why-this-drops-dokploy).

**The swarm exists only because Dokploy wanted one.** It has a single node and
no services. `docker swarm leave --force` during decommissioning costs nothing.

### sshd on port 2222

`/etc/ssh/sshd_config` sets `Port 2222`, with `PasswordAuthentication no` and
`PermitRootLogin no`. Dokploy used to SSH to the host at its own tailnet
address on that port. Every script in this repo uses `SOURCE_SSH_PORT=2222`
for robco. The target has no such constraint.

## Secrets in use

Six, enumerated with their locations in [03-secrets.md](03-secrets.md).

## Deliberately out of scope

- **Email.** All these zones have MX records at `1984.is`, an inherited
  arrangement with no server-side access. Nothing here touches MX or SRV
  records, and nothing should. Deleting one would break mail irreversibly.
- **Other hosts.** `ncr`, `vaultec` and `enclave` share the LAN and tailnet.
  `binflix.is` is served from `vaultec`, not here. `bgunnarsson.dev`'s apex
  points at a second tunnel whose connector runs on `ncr`. None of that moves
  with these websites.
