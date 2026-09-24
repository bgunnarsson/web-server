# web-server

Everything needed to move the websites off **robco** and onto another machine,
so robco can be repurposed as a remote dev box.

Captured from the live host on 2026-09-24. Seven stacks, thirteen hostnames,
2.1 GB of data, one Cloudflare tunnel.

## Start here

1. Read [docs/01-inventory.md](docs/01-inventory.md) — what robco actually
   runs, including two surprises: Dokploy is already gone, and the swarm is
   vestigial.
2. Read [docs/02-architecture.md](docs/02-architecture.md) — how a request
   reaches a site, and why the public cutover is not a DNS change.
3. Follow [docs/04-migration-runbook.md](docs/04-migration-runbook.md).

```bash
cp config/hosts.env.example config/hosts.env   # fill this in first
scripts/00-preflight.sh
```

## What moves

| Stack | Hostnames | Data |
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
  sites.tsv            the site registry; the scripts read this
  traefik/             static + dynamic Traefik config for the target
stacks/
  traefik/             edge router, bring up first
  <site>/              one docker-compose.yml + .env.example per site
scripts/               numbered, run in order
docs/                  the reasoning behind all of it
```

## Scripts

| | |
|---|---|
| `00-preflight.sh` | check both ends. Read-only |
| `10-collect-secrets.sh` | gather secrets from robco into `secrets/` |
| `11-backup-volumes.sh` | consistent snapshot of all persistent data |
| `20-provision-target.sh` | docker, Tailscale, network, Traefik on the target |
| `30-restore-volumes.sh` | load a snapshot into the target's volumes |
| `40-deploy-stacks.sh` | clone repos, build, start. Also the redeploy command |
| `50-cutover-dns.sh` | `check` / `tunnel` / `tailnet` / `rollback` |
| `60-verify.sh` | prove it worked. Read-only, non-zero exit on failure |
| `90-decommission-robco.sh` | `stop` / `archive` / `purge`, in that order |

Most take `DRY_RUN=1`. `50-` and `90-` prompt before anything destructive;
`ASSUME_YES=1` skips the prompts.

## Two things to know before you start

**This drops Dokploy, on purpose.** Its control plane is not running on robco
any more — only its leftovers are. The stacks here are plain `docker compose`.
You lose the web UI and push-to-deploy; you gain a setup that is fully
described by this repo. The reasoning and the trade-off are in
[docs/02-architecture.md](docs/02-architecture.md#why-this-drops-dokploy).

**No secrets are committed.** `secrets/`, `*.env` and `backups/` are
gitignored. The GitHub tokens sitting in robco's repos are expired Dokploy
artifacts and cannot be reused — you need to create one PAT. See
[docs/03-secrets.md](docs/03-secrets.md), which also flags a live Cloudflare
token hard-coded in `~/servset/cloudflare-tunnel/cf-common.sh` that is worth
rotating.

## Rolling back

Until `90-decommission-robco.sh purge` runs, robco is intact and
`scripts/50-cutover-dns.sh rollback` restores service in seconds.
[docs/06-rollback.md](docs/06-rollback.md).
