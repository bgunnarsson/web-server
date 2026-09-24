# Rollback

Rollback is cheap right up until `90-decommission-robco.sh purge`. Until then
robco still has every container, volume and config file it started with.

## The one command

```bash
scripts/50-cutover-dns.sh rollback
```

Stops cloudflared on the target, starts it on robco. Public sites are back
within seconds. No DNS changes, nothing to propagate.

Then check:

```bash
scripts/50-cutover-dns.sh check     # expect exactly 1 connector
curl -I https://galdur.dev/
```

## If the tailnet hostname was already repointed

`50-cutover-dns.sh tailnet` moved `design.bgunnarsson.dev` to the target's
Tailscale IP. To put it back, set `TARGET_TAILSCALE_IP=100.87.155.125`
(robco's) in `config/hosts.env` and re-run the `tailnet` sub-command, or set
the A record by hand in the dashboard. **Keep it DNS-only / grey cloud.** TTL
is 60 seconds, so it takes effect quickly.

## If robco's containers were already stopped

```bash
scripts/90-decommission-robco.sh stop    # only stops; data untouched
```

is reversible by hand:

```bash
sudo systemctl enable --now cloudflared
docker start dokploy-traefik
for d in $(docker run --rm -v /etc/dokploy:/x:ro alpine ls /x/compose); do
  docker compose -p "$d" start
done
```

## If `archive` already ran

It leaves the swarm and moves `/etc/dokploy` to `/etc/dokploy.retired-<date>`.
The sites still run — Traefik and the compose projects do not depend on either.
To fully undo:

```bash
sudo mv /etc/dokploy.retired-* /etc/dokploy
```

The swarm does not need recreating; nothing used it.

## After `purge`

Volumes are gone and **this cannot be undone on the machine**. Recovery means
restoring from a snapshot:

```bash
scripts/30-restore-volumes.sh backups/<timestamp>
```

`archive` takes a fresh backup before removing anything, so there is always one
snapshot newer than the destruction — provided it is stored somewhere other
than robco. Copy `backups/` off the machine before running `purge`.

## Deciding

| Symptom | Do this |
|---|---|
| A site 404s or 502s on the target | Fix on the target; robco is idle, no rush |
| All sites down after cutover | `rollback`, then investigate |
| Sites work intermittently | Two connectors — `check`, stop the extra one |
| penpot loads but files are empty | Stop penpot, re-run `30-restore-volumes.sh` with `FORCE=1` |
| penpot rejects logins | `PENPOT_SECRET_KEY` does not match the original |
| binbox logs everyone out | `BETTER_AUTH_SECRET` does not match; cosmetic, fix and restart |
| Cert errors on design.bgunnarsson.dev | Traefik's `CF_DNS_API_TOKEN` — check `docker logs traefik \| grep -i acme` |
