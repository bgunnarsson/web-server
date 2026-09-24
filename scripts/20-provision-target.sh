#!/usr/bin/env bash
# 20-provision-target.sh — bring a bare machine up to the point where the
# stacks can be deployed: docker, tailscale, cloudflared, the shared network,
# and Traefik with its config.
#
# Idempotent: safe to re-run. Run from your workstation (it drives the target
# over ssh), or on the target itself with LOCAL=1.
. "$(dirname "$0")/lib.sh"
load_hosts
: "${TARGET_HOST:?set TARGET_HOST in config/hosts.env}"

run() { if [ "${LOCAL:-0}" = "1" ]; then bash -c "$*"; else ssh_target "$*"; fi; }
put() { if [ "${LOCAL:-0}" = "1" ]; then cp "$1" "$2"; else
          scp -P "${TARGET_SSH_PORT:-22}" -q "$1" "${TARGET_SSH_USER:+$TARGET_SSH_USER@}$TARGET_HOST:$2"; fi; }

step "Docker"
if run 'command -v docker >/dev/null'; then
  c_ok "already installed: $(run 'docker --version')"
else
  c_warn "installing docker (needs sudo on the target)"
  run 'curl -fsSL https://get.docker.com | sudo sh'
  run 'sudo usermod -aG docker "$USER" && sudo systemctl enable --now docker'
  c_warn "log out and back in for the docker group to take effect, then re-run"
fi

step "Tailscale"
# Needed for design.bgunnarsson.dev, which is reachable only over the tailnet.
if run 'command -v tailscale >/dev/null'; then
  c_ok "installed"
  run 'tailscale status >/dev/null 2>&1' && c_ok "logged in" \
    || c_warn "run on the target:  sudo tailscale up"
else
  run 'curl -fsSL https://tailscale.com/install.sh | sudo sh'
  c_warn "then run on the target:  sudo tailscale up"
fi

step "Shared 'proxy' network"
run 'docker network inspect proxy >/dev/null 2>&1 || docker network create proxy'
c_ok "proxy network present"

step "Directory layout"
run "mkdir -p '$TARGET_ROOT'/stacks '$TARGET_ROOT'/traefik/dynamic"
c_ok "$TARGET_ROOT"

step "Traefik config"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
sed "s|CHANGEME@example.com|${ACME_EMAIL:?set ACME_EMAIL in config/hosts.env}|" \
  "$REPO_ROOT/config/traefik/traefik.yml" > "$tmp/traefik.yml"
put "$tmp/traefik.yml" "$TARGET_ROOT/traefik/traefik.yml"
put "$REPO_ROOT/config/traefik/dynamic/middlewares.yml" "$TARGET_ROOT/traefik/dynamic/middlewares.yml"
put "$REPO_ROOT/stacks/traefik/docker-compose.yml" "$TARGET_ROOT/traefik/docker-compose.yml"
# acme.json must be 0600 or Traefik refuses to start.
run "touch '$TARGET_ROOT/traefik/dynamic/acme.json' && chmod 600 '$TARGET_ROOT/traefik/dynamic/acme.json'"
c_ok "traefik.yml, middlewares.yml, acme.json"

step "Traefik secrets"
if [ -f "$SECRETS_DIR/traefik.env" ]; then
  put "$SECRETS_DIR/traefik.env" "$TARGET_ROOT/traefik/.env"
  run "chmod 600 '$TARGET_ROOT/traefik/.env'"
  c_ok ".env written"
else
  c_warn "secrets/traefik.env missing — run 10-collect-secrets.sh first"
fi

step "Starting Traefik"
run "cd '$TARGET_ROOT/traefik' && docker compose up -d"
sleep 3
run "docker ps --filter name=traefik --format '{{.Status}}'" | sed 's/^/    /'

step "cloudflared"
# NOT started here on purpose. Two connectors serving the same tunnel would
# split traffic between robco and the target mid-migration. 50-cutover-dns.sh
# starts it at the moment of cutover. See docs/04-migration-runbook.md.
if run 'command -v cloudflared >/dev/null'; then
  c_ok "installed (left stopped until cutover)"
else
  c_warn "install it on the target now, but do NOT start it yet:"
  echo   "    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null"
  echo   "    (Debian/Ubuntu) see https://pkg.cloudflare.com  —  (Arch) pacman -S cloudflared"
fi

echo
c_ok "target provisioned — next: scripts/40-deploy-stacks.sh"
