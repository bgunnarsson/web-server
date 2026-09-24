# Rollback

Rollback is cheap right up until `90-decommission-robco.sh purge`. Until then
robco still has every container, volume and config file it started with.

## The one command

```bash
scripts/50-cutover-dns.sh rollback
```

In one step, it:

1. Stops cloudflared on the target and starts it on robco. Public sites are
   back within seconds, with no DNS change.
2. Starts every Dokploy app's containers on robco, including binbox and
   penpot, which `11-backup-volumes.sh --freeze` stopped.
3. Points `design.bgunnarsson.dev` back at robco's tailnet IP
   (`SOURCE_TAILSCALE_IP`), DNS-only. TTL is 60 seconds.

Then check:

```bash
scripts/50-cutover-dns.sh check     # expect exactly 1 connector, robco's IP
curl -I https://galdur.dev/
```

**What rollback loses:** anything written to binbox or penpot on the target
after the restore. robco's data is exactly as it was at the freeze. If the
target ran for a while and took real writes, snapshot the target before
rolling back and decide what to keep. The volumes are ordinary docker volumes
and `11-`'s commands work there by hand.

## If Dokploy removed robco's containers

Changing an app's server in Dokploy may or may not clean up the old one.
`00-preflight.sh` reports how many Dokploy apps are still running on robco. If
some are gone, rollback cannot bring them back. Redeploy those apps to robco
from Dokploy instead. The volumes are still there, and a redeploy under the
same app name reuses them. Check with `docker volume ls` that it did.

## If `90- stop` already ran

`stop` only stops things. The `rollback` command above reverses it, except for
Traefik:

```bash
docker start dokploy-traefik
scripts/50-cutover-dns.sh rollback
```

## If `90- archive` already ran

robco is no longer a Dokploy server, has left the swarm, and `/etc/dokploy`
has moved to `/etc/dokploy.retired-<date>`. The volumes are still there.
Re-add robco as a server in Dokploy and redeploy the apps to it. Under the same
app names they reuse the volumes. If the names change, copy the data across by
hand (`30-` refuses to target robco, on purpose). Dokploy recreates the swarm
when the server is added.

## After `purge`

Volumes are gone and **this cannot be undone on the machine**. Recovery means
deploying the apps somewhere and restoring from a snapshot with
`30-restore-volumes.sh backups/<timestamp>`, with that machine as
`TARGET_HOST`.

`archive` takes a fresh backup before removing anything, so there is always one
snapshot newer than the destruction — provided it is stored somewhere other
than robco. Copy `backups/` off the machine before running `purge`.

## Deciding

| Symptom | Do this |
|---|---|
| A site 404s or 502s on the target | Fix on the target; robco is idle, no rush |
| All sites down after cutover | `rollback`, then investigate |
| Sites work intermittently | Two connectors — `check`, stop the extra one |
| penpot loads but files are empty | Re-run `30-restore-volumes.sh`. It wipes and reloads |
| penpot rejects logins | `PENPOT_SECRET_KEY` in Dokploy does not match the original |
| binbox logs everyone out | `BETTER_AUTH_SECRET` does not match; cosmetic, fix and redeploy |
| Cert errors on design.bgunnarsson.dev | Traefik on the target lacks DNS-01 — re-run `setup-letsencrypt-cloudflare.sh`, check `docker logs dokploy-traefik 2>&1 \| grep -i acme` |
| design.bgunnarsson.dev 404s on the target | No HTTPS router — run `~/servset/dokploy/enable-https.sh` on the target |
