# Turning robco into a remote dev machine

After `90-decommission-robco.sh archive`, robco serves no websites. This is
what to keep, what to remove, and what to change.

## Keep

| | Why |
|---|---|
| **Tailscale** | The only way in. `100.87.155.125`, unchanged. Behind CGNAT there is no alternative. |
| **sshd on :2222** | Already publickey-only, no root login, tailnet-reachable. Fine as a dev box's entry point. |
| **Docker** | Useful for dev containers and devcontainers. Keep the daemon, drop the swarm. |
| **`~/servset/`** | The Cloudflare scripts are still handy. Rotate the token baked into `cf-common.sh` first — see [03-secrets.md](03-secrets.md). |

## Remove

| | Command |
|---|---|
| Docker swarm | `docker swarm leave --force` (done by `archive`) |
| Dokploy state | moved to `/etc/dokploy.retired-*` by `archive`; delete when sure |
| cloudflared | `sudo systemctl disable --now cloudflared`, then uninstall if you want |
| Site volumes and images | `90-decommission-robco.sh purge` — frees roughly 2.1 GB of volumes plus images and build cache |

## Change

**ssh back to 22, if you want.** Port 2222 exists only because Dokploy wanted
it. On the tailnet the port is not a security measure either way. If you change
it, update `SOURCE_SSH_PORT` in `config/hosts.env` and anything else that
hard-codes 2222.

**Ports 80 and 443 come free.** Once Traefik is gone, nothing listens there.
Handy for a dev server without arguing with a reverse proxy.

**Swarm ports 2377 and 7946 close** when the swarm is gone. They were
LAN/tailnet-only regardless — this machine is behind CGNAT and has never been
reachable from the internet.

## What robco loses

Nothing that matters for dev work. The machine was a web server by
configuration, not by hardware: a ThinkCentre M910q on a home LAN behind
carrier NAT. After this it is the same machine with ~2 GB more free disk and
fewer daemons.

## A note on the other boxes

`ncr`, `vaultec` and `enclave` share the LAN and tailnet and are **not** part
of this migration. If you pick `ncr` as the target, read the second-tunnel
warning in [05-dns-cloudflare.md](05-dns-cloudflare.md) first: the `dokploy`
tunnel on ncr has ingress rules pointing at `http://robco:80`, which will be a
dev machine.
