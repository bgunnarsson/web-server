# Secrets

**No secret value is in this repo, and none should ever be committed.**
`secrets/` and `*.env` are gitignored; `*.env.example` files are the committed
templates. `scripts/10-collect-secrets.sh` populates `secrets/` from the live
host.

## The six secrets

| # | Secret | Lives on robco at | Needed by | Can it be regenerated? |
|---|---|---|---|---|
| 1 | `TUNNEL_TOKEN` | `/etc/cloudflared/env` (root, 0600) | cloudflared on the target | Yes — Cloudflare dashboard → tunnel → reissue token |
| 2 | `CF_DNS_API_TOKEN` | env of the `dokploy-traefik` container | Traefik, for Let's Encrypt DNS-01 | Yes — create a new API token |
| 3 | `PENPOT_SECRET_KEY` | penpot's `.env` | penpot backend + exporter | **No.** Changing it invalidates every existing session and some stored data |
| 4 | `POSTGRES_PASSWORD` | penpot's `.env` | penpot's database | Yes, but change it in both places at once |
| 5 | `BETTER_AUTH_SECRET` | binbox's `.env` | binbox sessions | Changing it logs everyone out; otherwise harmless |
| 6 | `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` | binbox's `.env` | Google sign-in on galdur.dev | From Google Cloud Console, if lost |

Plus a **GitHub token** you must create yourself — see below.

## Retrieving them

```bash
scripts/10-collect-secrets.sh
```

writes `secrets/{bgunnarsson-com,bincms,binman,binsby,binvim,binbox,penpot}.env`
plus `secrets/cloudflared.env` and `secrets/traefik.env`, all mode 0600.

It reads the root-owned `/etc/dokploy` through a throwaway container rather
than asking for sudo. `/etc/cloudflared/env` is mode 0600 root-only and a
container mount cannot get around that, so if that one comes back empty, run
on robco:

```bash
sudo cat /etc/cloudflared/env > secrets/cloudflared.env
chmod 600 secrets/cloudflared.env
```

The account and tunnel IDs are encoded inside the tunnel token itself:

```bash
sudo sh -c 'set -a; . /etc/cloudflared/env; printf "%s" "$TUNNEL_TOKEN"' \
  | base64 -d | jq -r '"account=\(.a)  tunnel=\(.t)"'
```

## GitHub access — you have to create this one

Every repo under `/etc/dokploy/compose/*/code/.git/config` has a GitHub App
token embedded in its remote URL:

```
https://oauth2:ghs_...@github.com/bgunnarsson/binbox.git
```

Dokploy minted those, they are short-lived, and **all of them have expired**.
They are useless for the migration. Do not try to reuse them, and treat the
ones still on disk as garbage to be removed with the rest of `/etc/dokploy`.

Create one fine-grained PAT with **Contents: Read** on the six repos, put it in
`secrets/github.env` as `GITHUB_TOKEN=...`, and `40-deploy-stacks.sh` will use
it. It passes the token on the command line for the clone and then rewrites the
remote to the clean URL, so the token is never written into `.git/config` on
the target.

## Also in this repo: a token that should be revoked

`~/servset/cloudflare-tunnel/cf-common.sh` on robco has a Cloudflare API token
hard-coded as a fallback:

```bash
CF_API_TOKEN="${CF_API_TOKEN:-cfut_eqcPUJ...}"
```

It was still valid when this repo was written (2026-09-24) — it reads the
tunnel config and lists all ten zones. A token with `Zone:DNS:Edit` across
every zone, sitting in a plaintext file, is worth rotating as part of this
move. The scripts here take `CF_API_TOKEN` from `config/hosts.env` only and
have no baked-in fallback.

## Handling rules

- Copy `secrets/` between machines over `scp`/`rsync` on the tailnet. Never
  through a chat, a paste site, or a public repo.
- `secrets/` is mode 0700, its contents 0600. Keep it that way.
- Volume backups in `backups/` contain the full application database. They are
  as sensitive as the secrets — gitignored for the same reason.
- After the move, delete `secrets/` from any machine that no longer needs it.
