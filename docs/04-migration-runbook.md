# Migration runbook

Dokploy does the deploying. This repo covers what a redeploy does not: the
data, the tunnel, the tailnet hostname, and Traefik's hand-made HTTPS setup.

Phases 1–3 change nothing user-visible and can be done at any pace; the sites
stay up on robco throughout. Phase 4 is the cutover. Every script runs **on
robco** and reaches the target over ssh.

Before starting: `cp config/hosts.env.example config/hosts.env` and fill it in.

---

## Phase 1 — Set up the target in Dokploy

In the Dokploy panel (on ncr):

1. **Add the target as a server.** Dokploy installs docker, joins it to a
   swarm, creates `dokploy-network` and starts `dokploy-traefik`.
2. **Point every app at the new server and deploy it.** All seven. Env vars
   and domains come along because Dokploy holds them. If Dokploy will not let
   you change an existing app's server, create the app again on the new server
   with the same repo, env and domains. The scripts find volumes by suffix, so
   a different app name is fine.
3. **Check robco's copies are still running** afterwards (`docker ps` on
   robco). They are what serves the sites until cutover, and what rollback
   returns to. `00-preflight.sh` counts them.

binbox and penpot come up **empty** on the target. That is expected; phase 3
fills them.

## Phase 2 — Things Dokploy does not carry

On the **target**:

```bash
sudo tailscale up                        # penpot is tailnet-only
tailscale ip -4                          # -> TARGET_TAILSCALE_IP in hosts.env
sudo pacman -S cloudflared               # or pkg.cloudflare.com on Debian. Do NOT start it
```

Then copy `~/servset` from robco to the target and run its Traefik setup there.
These are the hand edits robco's Traefik has that a fresh Dokploy server does
not (see [01-inventory.md](01-inventory.md#traefik-was-changed-by-hand)):

```bash
tar -C ~ -cf - servset | ssh TARGET 'tar -C ~ -xf -'      # from robco
# then on the target:
~/servset/dokploy/setup-letsencrypt-cloudflare.sh         # DNS-01 + CF_DNS_API_TOKEN
~/servset/dokploy/enable-https.sh                         # HTTPS routers, incl. penpot's
```

The token `setup-letsencrypt-cloudflare.sh` asks for is robco's
`CF_DNS_API_TOKEN`, or a new one with the same scopes
([03-secrets.md](03-secrets.md)). Without these two steps
`design.bgunnarsson.dev` has no HTTPS route and no certificate.

Then from robco:

```bash
scripts/00-preflight.sh
```

It checks that every hostname has a running container on the target,
that Traefik has its token and penpot's router, Tailscale, cloudflared
(installed, **not** running), disk space and the Cloudflare API token. Fix
everything it flags.

## Phase 3 — Rehearse the data move

```bash
scripts/11-backup-volumes.sh             # live snapshot; sites stay up
scripts/30-restore-volumes.sh            # stream it into the target's volumes
```

`11-` takes about three minutes. SQLite goes through `.backup` and Postgres
through `pg_dump`, so the snapshot is consistent even while the apps run.

`30-` finds the binbox and penpot volumes on the target, stops those apps,
**wipes and reloads** their volumes over ssh, and starts them again. It checks
the snapshot's checksums first and compares penpot's file count afterwards.
It is safe to run as often as you like.

Now test the target **before** any traffic moves. The sites are not on it yet,
so test by Host header, on the target:

```bash
curl -I -H 'Host: galdur.dev' http://localhost/
```

`200` means router and app both work. `404` means Traefik has no router for
that hostname. `502` means the router matched but the app is down. Log into
penpot over the tailnet by the target's IP too, if you like. The hostname
still points at robco.

## Phase 4 — Cutover

```bash
scripts/50-cutover-dns.sh check          # look before you leap
scripts/11-backup-volumes.sh --freeze    # stops binbox + penpot on robco, snapshots
scripts/30-restore-volumes.sh            # the final data, onto the target
scripts/50-cutover-dns.sh tunnel         # move the connector
scripts/50-cutover-dns.sh tailnet        # repoint design.bgunnarsson.dev
scripts/60-verify.sh
```

`--freeze` is what makes this lossless. Anything written to robco after the
rehearsal snapshot would otherwise never reach the target. It stops galdur.dev
and penpot on robco, so they are down from that point until the tunnel moves,
about ten minutes in total. The five static sites never go down.

`tunnel` refuses to run unless every public hostname already answers through
the target's Traefik. It then copies robco's tunnel token straight to the
target, installs the same systemd unit, stops cloudflared on robco and starts
it on the target. The public sites blip for a few seconds. No DNS changes: the
CNAMEs already point at the tunnel.

If anything is wrong: `scripts/50-cutover-dns.sh rollback`. See
[06-rollback.md](06-rollback.md).

## Phase 5 — Soak, then decommission

Leave robco as it is for a few days. Its apps (binbox and penpot are stopped
by `--freeze`) are what rollback returns to.

When you are satisfied:

```bash
scripts/90-decommission-robco.sh stop      # reversible
scripts/90-decommission-robco.sh archive   # remove robco from Dokploy, final backup, drop swarm
scripts/90-decommission-robco.sh purge     # delete volumes — NOT reversible
```

Also fix or remove the stale `http://robco:80` rules on ncr's `dokploy` tunnel
(`50-cutover-dns.sh check` lists them). Run `purge` only after `60-verify.sh`
passes and `backups/` is copied off robco. Then see
[07-repurpose-robco.md](07-repurpose-robco.md).

---

## Timing

| Phase | Time | Sites affected? |
|---|---|---|
| 1 Dokploy | 20–40 min (binbox build) | no |
| 2 target setup | 15 min | no |
| 3 rehearsal | 10 min | no |
| 4 cutover | ~10 min | galdur.dev + penpot down ~10 min; the rest blip for seconds |
| 5 decommission | your own pace | no |

## Things that bite

- **Two live connectors.** Requests land on whichever machine answers, so the
  sites work intermittently and nothing looks broken. `00-` fails if
  cloudflared is already running on the target; `60-` fails unless there is
  exactly one connector.
- **Cutting over from the rehearsal snapshot.** Always `--freeze` for the
  final one. Otherwise the writes in between are lost.
- **A redeploy on robco after cutover.** While robco is still a server in
  Dokploy, a deploy aimed there brings the old apps back up. `archive` makes
  you remove it first.
- **Forgetting `enable-https.sh` on the target.** penpot then has no HTTPS
  router. Run it again whenever you add a site, exactly as on robco.
- **`design.bgunnarsson.dev` proxied or on a tunnel.** That publishes a design
  tool with no authentication in front of it. The A record stays grey-cloud,
  and `tunnel-exclude.txt` must travel with `~/servset`.
- **A global HTTP→HTTPS redirect.** Infinite redirect loop behind Cloudflare.
  See [02-architecture.md](02-architecture.md).
