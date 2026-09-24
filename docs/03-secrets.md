# Secrets

**No secret value is in this repo, and none should ever be committed.**
`config/hosts.env` and `backups/` are gitignored.

## App secrets: Dokploy has them

`PENPOT_SECRET_KEY`, penpot's `POSTGRES_PASSWORD`, binbox's
`BETTER_AUTH_SECRET` and Google OAuth credentials all live in each app's
environment in Dokploy. They travel with the app when it is deployed to the new
server, so nothing here collects or copies them.

Two of them must **not** change during the move, or the restored data stops
matching:

| Secret | If it changes |
|---|---|
| `PENPOT_SECRET_KEY` | Every session is invalidated and some stored data becomes unreadable |
| penpot `POSTGRES_USER` | The restore connects as `penpot`; the dump is restored `--no-owner`, so the password itself may differ |
| `BETTER_AUTH_SECRET` | Everyone is logged out of galdur.dev. Harmless otherwise |

If you recreate an app instead of moving it, copy its env from the old app in
Dokploy rather than retyping it.

## The ones outside Dokploy

| Secret | Lives on robco at | Needed by | How it moves |
|---|---|---|---|
| `TUNNEL_TOKEN` | `/etc/cloudflared/env` (root, 0600) | cloudflared on the target | `50-cutover-dns.sh tunnel` reads it with sudo and writes it to the target's `/etc/cloudflared/env` over ssh. It is never stored anywhere else |
| `CF_DNS_API_TOKEN` | env of the `dokploy-traefik` container | Traefik on the target, for Let's Encrypt DNS-01 | you paste it into `setup-letsencrypt-cloudflare.sh` on the target |
| `CF_API_TOKEN` | nowhere yet. Create it | the scripts here | `config/hosts.env` |

To read robco's DNS token for pasting:

```bash
docker inspect dokploy-traefik --format '{{range .Config.Env}}{{println .}}{{end}}' | grep CF_DNS_API_TOKEN
```

Or create a new one with `Zone:DNS:Edit` + `Zone:Zone:Read` on all zones. That
is cleaner, because robco's copy can then be revoked with the machine.

`CF_API_TOKEN` needs `Account:Cloudflare Tunnel:Read` (connector counts,
ingress), `Zone:DNS:Edit` (the tailnet record) and `Zone:Zone:Read`.

The account and tunnel IDs are encoded inside the tunnel token itself:

```bash
sudo sh -c 'set -a; . /etc/cloudflared/env; printf "%s" "$TUNNEL_TOKEN"' \
  | base64 -d | jq -r '"account=\(.a)  tunnel=\(.t)"'
```

## A token that should be revoked

`~/servset/cloudflare-tunnel/cf-common.sh` on robco has a Cloudflare API token
hard-coded as a fallback:

```bash
CF_API_TOKEN="${CF_API_TOKEN:-cfut_eqcPUJ...}"
```

It was still valid when this repo was written (2026-09-24) — it reads the
tunnel config and lists all ten zones. A token with `Zone:DNS:Edit` across
every zone, sitting in a plaintext file, is worth rotating as part of this
move, especially now that `~/servset` gets copied to the target. The scripts
here take `CF_API_TOKEN` from `config/hosts.env` only and have no baked-in
fallback.

## Handling rules

- Volume backups in `backups/` contain the full application database. Treat
  them like the secrets: gitignored, never on shared storage.
- Copy `backups/` off robco before `90-decommission-robco.sh purge`, by
  `tar | ssh` over the tailnet. Never through a chat, a paste site or a public repo.
- Once the target is proven, delete robco's `/etc/cloudflared/env` along with
  the rest of its web-server state. Two machines holding a live tunnel token is
  one more than needed.
