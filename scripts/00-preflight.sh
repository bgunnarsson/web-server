#!/usr/bin/env bash
# 00-preflight.sh — check both ends before anything is moved. Read-only.
# Run on robco, after the target has been added to Dokploy and the apps deployed.
. "$(dirname "$0")/lib.sh"
load_hosts
require_source

rc=0
bad()  { c_err "$*"; rc=1; }

step "Local tooling (robco)"
for t in ssh docker jq curl tar sha256sum sudo; do
  command -v "$t" >/dev/null 2>&1 && c_ok "$t" || bad "$t missing"
done
docker ps -q >/dev/null 2>&1 && c_ok "docker usable" || bad "docker not usable"
n=0; for p in $(robco_projects); do
  [ -n "$(docker ps -q --filter "label=com.docker.compose.project=$p")" ] && n=$((n+1))
done
c_ok "$n Dokploy apps running here (rollback falls back to these)"

step "Target host (${TARGET_HOST:-<unset>})"
if [ -z "${TARGET_HOST:-}" ]; then
  bad "TARGET_HOST not set in config/hosts.env"
elif ! ssh_target true 2>/dev/null; then
  bad "cannot ssh to $TARGET_HOST:${TARGET_SSH_PORT:-22} from robco"
else
  require_target
  c_ok "ssh reachable on :${TARGET_SSH_PORT:-22}"
  ssh_target 'docker ps -q >/dev/null 2>&1' && c_ok "docker usable without sudo" \
    || bad "docker not usable by ${TARGET_SSH_USER:-this user} — add it to the docker group"

  # Dokploy installs its own Traefik when the server is added.
  if ssh_target 'docker ps --format "{{.Names}}"' | grep -qx dokploy-traefik; then
    c_ok "dokploy-traefik running (server is set up in Dokploy)"
    env=$(ssh_target 'docker inspect dokploy-traefik --format "{{range .Config.Env}}{{println .}}{{end}}"')
    grep -q '^CF_DNS_API_TOKEN=.' <<<"$env" && c_ok "Traefik has CF_DNS_API_TOKEN (DNS-01 certs)" \
      || bad "Traefik has no CF_DNS_API_TOKEN — run ~/servset/dokploy/setup-letsencrypt-cloudflare.sh on the target"
    ssh_target 'cat /etc/dokploy/traefik/dynamic/websecure-routers.yml 2>/dev/null' | grep -q 'design.bgunnarsson.dev' \
      && c_ok "HTTPS router for design.bgunnarsson.dev present" \
      || bad "no HTTPS router for design.bgunnarsson.dev — run ~/servset/dokploy/enable-https.sh on the target after deploying penpot"
  else
    bad "no dokploy-traefik on the target — add it as a server in Dokploy first"
  fi

  labels=$(ssh_target 'docker ps --format "{{.Labels}}"')
  while IFS=$'\t' read -r name domains exposure stateful; do
    h="${domains%%,*}"
    grep -qF "Host(\`$h\`)" <<<"$labels" && c_ok "$name deployed (serves $h)" \
      || bad "$name: no running container serves $h — deploy it to $TARGET_HOST in Dokploy"
  done < <(sites)

  free_kb=$(ssh_target 'df -Pk /var/lib/docker 2>/dev/null || df -Pk /' | awk 'NR==2{print $4}')
  if [ "${free_kb:-0}" -ge 10485760 ]; then c_ok "$((free_kb/1048576)) GB free for docker"
  else c_warn "only $((${free_kb:-0}/1048576)) GB free — the restore needs ~2.1 GB plus headroom"; fi

  tip=$(ssh_target 'tailscale ip -4 2>/dev/null' || true)
  if [ -z "$tip" ]; then bad "tailscale not up on the target (penpot is tailnet-only)"
  elif [ "$tip" != "${TARGET_TAILSCALE_IP:-}" ]; then
    bad "target tailnet IP is $tip but TARGET_TAILSCALE_IP=${TARGET_TAILSCALE_IP:-<unset>}"
  else c_ok "tailscale up, $tip"; fi

  ssh_target 'command -v cloudflared >/dev/null' && c_ok "cloudflared installed" \
    || bad "cloudflared not installed on the target (Arch: pacman -S cloudflared; Debian: pkg.cloudflare.com)"
  ssh_target 'systemctl is-active -q cloudflared' \
    && bad "cloudflared is already RUNNING on the target — two connectors split traffic" \
    || c_ok "cloudflared not running yet (correct until cutover)"
fi

step "Cloudflare API"
if [ -z "${CF_API_TOKEN:-}" ]; then
  bad "CF_API_TOKEN not set in config/hosts.env"
elif curl -sS "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$CF_TUNNEL_ID/connections" \
       -H "Authorization: Bearer $CF_API_TOKEN" | jq -e '.success' >/dev/null; then
  c_ok "token can read the tunnel"
else
  bad "token cannot read tunnel $CF_TUNNEL_ID — check scopes (Account:Cloudflare Tunnel:Read)"
fi

echo
[ "$rc" -eq 0 ] && c_ok "preflight passed" || c_warn "preflight found problems — fix them before continuing"
exit "$rc"
