# Migration runbook

Work through this in order. Phases 1–4 change nothing user-visible and can be
done at any pace; the sites stay up on robco throughout. Phase 5 is the cutover.

Before starting: `cp config/hosts.env.example config/hosts.env` and fill it in.

---

## Phase 1 — Check both ends

```bash
scripts/00-preflight.sh
```

Verifies ssh to both machines, docker, disk space on the target (want 20 GB+;
volumes alone are 2.1 GB), Tailscale, and that your Cloudflare token can read
the tunnel. Fix anything it flags before continuing.

## Phase 2 — Collect secrets and data

```bash
scripts/10-collect-secrets.sh     # on robco, or with ssh to it
scripts/11-backup-volumes.sh      # on robco
```

`10-` writes `secrets/*.env`. If `cloudflared.env` comes back empty, get it by
hand — [03-secrets.md](03-secrets.md) has the command. You must also create a
GitHub PAT and put it in `secrets/github.env`; the tokens on robco are expired.

`11-` writes a timestamped snapshot to `backups/`, roughly 1.3 GB and a few
minutes. SQLite goes through `.backup` and Postgres through `pg_dump` rather
than being copied as files, because both are live — a raw tar of either can
capture a torn database. A `SHA256SUMS` file is written and checked on restore.

Copy both to the target over the tailnet. robco has no rsync, so use
`tar | ssh`. Secrets go into the target's checkout of this repo, because
`40-deploy-stacks.sh` reads them from there. The snapshot goes to its own directory:

```bash
tar -C secrets -cf - . \
  | ssh TARGET 'mkdir -m 700 -p ~/web-server/secrets && tar -C ~/web-server/secrets -xf -'
tar -C backups/latest/ -cf - . \
  | ssh TARGET 'mkdir -p /srv/web-move/snapshot && tar -C /srv/web-move/snapshot -xf -'
```

## Phase 3 — Provision the target

```bash
scripts/20-provision-target.sh
```

Installs docker and Tailscale if missing, creates the `proxy` network and
`$TARGET_ROOT`, writes Traefik's config with your real ACME email, and starts
Traefik.

It deliberately **does not start cloudflared.** Two connectors on one tunnel
splits traffic between the two machines.

Then run `sudo tailscale up` on the target and put its tailnet IP into
`config/hosts.env` as `TARGET_TAILSCALE_IP`.

## Phase 4 — Deploy and restore

On the target, from a checkout of this repo with `secrets/` in place:

```bash
NO_START=1 scripts/40-deploy-stacks.sh   # clone, build, create volumes
scripts/30-restore-volumes.sh /srv/web-move/snapshot
scripts/40-deploy-stacks.sh              # start everything
```

The two-step start is what keeps the restore safe: `NO_START=1` creates the
named volumes without running anything, so the data lands before any process
opens those databases. `30-` refuses to write into a non-empty volume unless
you pass `FORCE=1`.

The binbox build is the slow one — it compiles `better-sqlite3` from source and
needs a few minutes.

Now check it **before** any traffic moves. The sites are not on DNS yet, so
test by Host header straight at the target's Traefik:

```bash
curl -I -H 'Host: galdur.dev' http://localhost/
curl -I -H 'Host: bgunnarsson.com' http://localhost/
```

`200` means the router and the app are both working. `404` means Traefik has no
router for that hostname (labels wrong, or the container is not on `proxy`).
`502` means the router matched but the app is down.

Also confirm the data actually arrived — log into penpot over the tailnet and
open a file, and check binbox's collection. **Do not cut over on a green
`docker ps` alone.**

## Phase 5 — Cutover

```bash
scripts/50-cutover-dns.sh check      # look before you leap
scripts/50-cutover-dns.sh tunnel     # move the connector
scripts/50-cutover-dns.sh tailnet    # repoint design.bgunnarsson.dev
scripts/60-verify.sh
```

The `tunnel` step stops cloudflared on robco, installs the same systemd unit on
the target, and starts it there. Public sites blip for a few seconds. No DNS
changes and nothing to propagate — the CNAMEs already point at the tunnel, and
only the machine answering it changes.

If anything is wrong: `scripts/50-cutover-dns.sh rollback` puts the connector
back on robco, which is still fully intact at this point. See
[06-rollback.md](06-rollback.md).

## Phase 6 — Soak, then decommission

Leave robco's containers running but idle for a few days. It costs nothing and
makes rollback instant.

When you are satisfied:

```bash
scripts/90-decommission-robco.sh stop      # reversible
scripts/90-decommission-robco.sh archive   # final backup, drop swarm + dokploy
scripts/90-decommission-robco.sh purge     # delete volumes — NOT reversible
```

Run `purge` only after `60-verify.sh` passes against the target and you have a
backup somewhere that is not robco. Then see
[07-repurpose-robco.md](07-repurpose-robco.md).

---

## Timing

| Phase | Time | Sites affected? |
|---|---|---|
| 1 preflight | minutes | no |
| 2 collect | 10–20 min (1.3 GB) | no |
| 3 provision | 10–30 min | no |
| 4 deploy + restore | 30–60 min (binbox build) | no |
| 5 cutover | **seconds of downtime** | yes |
| 6 decommission | your own pace | no |

## Things that bite

- **Two live connectors.** Requests land on whichever machine answers, so the
  sites work intermittently and nothing looks broken. `60-verify.sh` fails if
  the count is not exactly 1.
- **`PENPOT_SECRET_KEY` changed.** Sessions and some stored data become
  unreadable. Reuse the original value.
- **`design.bgunnarsson.dev` proxied or on a tunnel.** That publishes a design
  tool with no authentication in front of it. The A record stays grey-cloud.
- **Restoring into a running app.** Always restore with the app stopped.
- **`acme.json` not 0600.** Traefik refuses to start and the error is easy to
  miss in the log.
- **A global HTTP→HTTPS redirect.** Infinite redirect loop behind Cloudflare.
  See [02-architecture.md](02-architecture.md).
