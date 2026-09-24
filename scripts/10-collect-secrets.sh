#!/usr/bin/env bash
# 10-collect-secrets.sh — gather every secret this server needs into secrets/,
# which is gitignored. Run this ON robco (or with ssh access to it).
#
# Nothing here is ever committed. The output is a set of .env files you copy to
# the target by hand (or with 40-deploy-stacks.sh, which picks them up).
. "$(dirname "$0")/lib.sh"
load_hosts

mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"

step "Application .env files"
# Dokploy's project directory names carry a random suffix; map them by hand.
declare -A DOKPLOY_DIRS=(
  [bgunnarsson-com]=robco-bgunnarssoncom-oqffd0
  [bincms]=robco-bincms-lcqrhs
  [binman]=robco-binman-mdxsiq
  [binsby]=robco-binsby-akifw2
  [binvim]=robco-binvim-hor2ji
  [binbox]=robco-binbox-odjv6q
  [penpot]=robco-design-llggv8
)

for name in "${!DOKPLOY_DIRS[@]}"; do
  dir="${DOKPLOY_DIRS[$name]}"
  # /etc/dokploy is root-owned; read it through a container rather than sudo.
  content=$(run_source "docker run --rm -v /etc/dokploy:/x:ro alpine cat /x/compose/$dir/code/.env" 2>/dev/null || true)
  if [ -z "$content" ]; then c_warn "$name: no .env found"; continue; fi
  # APP_NAME / COMPOSE_PROJECT_NAME / DOCKER_CONFIG are Dokploy bookkeeping and
  # mean nothing on the target, so drop them.
  printf '%s\n' "$content" \
    | grep -vE '^(APP_NAME|COMPOSE_PROJECT_NAME|DOCKER_CONFIG)=' > "$SECRETS_DIR/$name.env" || true
  chmod 600 "$SECRETS_DIR/$name.env"
  n=$(grep -cE '^[A-Z_]+=' "$SECRETS_DIR/$name.env" || true)
  c_ok "$name.env ($n vars)"
done

step "Cloudflare tunnel token"
tok=$(run_source 'docker run --rm -v /etc/cloudflared:/cf:ro alpine sh -c "grep -h TUNNEL_TOKEN /cf/env"' 2>/dev/null \
      || run_source 'sudo grep -h TUNNEL_TOKEN /etc/cloudflared/env' 2>/dev/null || true)
if [ -n "$tok" ]; then
  printf '%s\n' "$tok" > "$SECRETS_DIR/cloudflared.env"
  chmod 600 "$SECRETS_DIR/cloudflared.env"
  c_ok "cloudflared.env"
  # The account and tunnel ids are base64-encoded inside the token itself.
  printf '%s' "${tok#TUNNEL_TOKEN=}" | base64 -d 2>/dev/null \
    | jq -r '"    account=\(.a)  tunnel=\(.t)"' 2>/dev/null || true
else
  c_warn "could not read /etc/cloudflared/env — it is root-only (mode 0600)."
  c_warn "run on robco:  sudo cat /etc/cloudflared/env > secrets/cloudflared.env"
fi

step "Traefik Let's Encrypt DNS-01 token"
cf=$(run_source "docker inspect dokploy-traefik --format '{{range .Config.Env}}{{println .}}{{end}}'" 2>/dev/null \
     | grep '^CF_DNS_API_TOKEN=' || true)
if [ -n "$cf" ]; then
  printf '%s\n' "$cf" > "$SECRETS_DIR/traefik.env"
  chmod 600 "$SECRETS_DIR/traefik.env"
  c_ok "traefik.env"
else
  c_warn "CF_DNS_API_TOKEN not found on the traefik container"
fi

step "GitHub access for the application repos"
cat > "$SECRETS_DIR/github.env" <<'EOF'
# The repos on robco were cloned by Dokploy using short-lived GitHub App tokens
# (ghs_... embedded in each .git/config). Those are expired and unusable — do
# NOT try to reuse them.
#
# Create ONE fine-grained PAT with Contents:Read on these repos and put it here:
#   bgunnarsson/bgunnarsson.com  bgunnarsson/bincms-web  bgunnarsson/binman-web
#   bgunnarsson/binsby-web       bgunnarsson/binvim-web  bgunnarsson/binbox
GITHUB_TOKEN=
EOF
chmod 600 "$SECRETS_DIR/github.env"
c_ok "github.env (template — you must fill in GITHUB_TOKEN)"

echo
c_ok "secrets collected in $SECRETS_DIR (gitignored, mode 700)"
c_warn "review each file before using it; see docs/03-secrets.md"
