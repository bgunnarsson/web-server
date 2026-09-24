# web-server

Everything needed to move the websites off **robco** and onto another machine,
so robco can be repurposed as a remote dev box.

Captured from the live host on 2026-09-24. Seven apps, thirteen hostnames,
2.1 GB of data, one Cloudflare tunnel.

## The short version

The sites are Dokploy apps, and the Dokploy panel runs on **ncr**. robco is
just one of its remote servers. So the move is mostly done in Dokploy:
**add the new server, point each app at it, redeploy.**

A redeploy does not carry four things, and that is what this repo handles:

1. **Data.** binbox (1.3 GB of SQLite and images) and penpot (Postgres and
   assets) come up empty on a new server. `11-` snapshots robco, `30-` streams
   the snapshot into the target's volumes.
2. **The tunnel connector.** `cloudflared` is a systemd service outside
   Dokploy. `50- tunnel` moves it.
3. **`design.bgunnarsson.dev`**, a tailnet-only A record to robco's Tailscale
   IP. `50- tailnet` repoints it.
4. **Traefik's hand edits**: DNS-01 certificates and the HTTPS routers, made on
   robco by `~/servset/dokploy/`. Re-run those scripts on the target.

## Start here

1. [docs/01-inventory.md](docs/01-inventory.md) — what robco actually runs.
2. [docs/02-architecture.md](docs/02-architecture.md) — how a request reaches
   a site, why the public cutover is not a DNS change, and who manages what.
3. Follow [docs/04-migration-runbook.md](docs/04-migration-runbook.md).

```bash
cp config/hosts.env.example config/hosts.env   # fill this in first
scripts/00-preflight.sh
```

Every script runs **on robco** and reaches the target over ssh.

## What moves

| App | Hostnames | Data |
|---|---|---|
| bgunnarsson-com | bgunnarsson.com + www | — |
| bincms | bincms.dev + www | — |
| binman | binman.is + www | — |
| binsby | binsby.com + www | — |
| binvim | binvim.dev + www | — |
| binbox | galdur.dev + www | 1.3 GB (SQLite + images) |
| penpot | design.bgunnarsson.dev | 74 MB (Postgres + assets) |

Six are public, reached through a Cloudflare tunnel. The seventh is
**tailnet-only and has no authentication in front of it** — see
[docs/05-dns-cloudflare.md](docs/05-dns-cloudflare.md) before touching its DNS.

## Layout

```
config/
  hosts.env.example    source/target/Cloudflare settings — copy to hosts.env
  sites.tsv            hostnames and exposure; what 60-verify.sh checks
scripts/               numbered, run in order
docs/                  the reasoning behind all of it
```

## Scripts

| | |
|---|---|
| `00-preflight.sh` | check both ends, including that Dokploy deployed every app. Read-only |
| `11-backup-volumes.sh` | consistent snapshot of all persistent data. `--freeze` for the final one |
| `30-restore-volumes.sh` | stream a snapshot into the target's volumes. Repeatable |
| `50-cutover-dns.sh` | `check` / `tunnel` / `tailnet` / `rollback` |
| `60-verify.sh` | prove it worked. Read-only, non-zero exit on failure |
| `90-decommission-robco.sh` | `stop` / `archive` / `purge`, in that order |

`30-`, `50-` and `90-` ask before anything destructive; `ASSUME_YES=1` skips
the prompts. `50-` takes `DRY_RUN=1` for its Cloudflare writes.

## No secrets are committed

The apps' secrets live in Dokploy and travel with the apps. The tunnel token
goes straight from robco to the target during cutover. `config/hosts.env` and
`backups/` are gitignored. [docs/03-secrets.md](docs/03-secrets.md) also flags
a live Cloudflare token hard-coded in `~/servset/cloudflare-tunnel/cf-common.sh`
that is worth rotating.

## Rolling back

Until `90-decommission-robco.sh purge` runs, robco is intact and
`scripts/50-cutover-dns.sh rollback` restores service in seconds.
[docs/06-rollback.md](docs/06-rollback.md).
