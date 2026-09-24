#!/usr/bin/env bash
# 50-cutover-dns.sh — move public traffic from robco to the target.
#
# The six public sites are reached as:
#   browser -> Cloudflare edge -> tunnel a1b9673e... -> cloudflared -> localhost:80
# so "cutover" means moving which machine runs that tunnel's connector. DNS
# already points at the tunnel (proxied CNAMEs to <id>.cfargotunnel.com) and
# does not need to change at all for those.
#
# The seventh, design.bgunnarsson.dev, is NOT on the tunnel: it is a DNS-only A
# record to robco's tailnet IP. That one genuinely does change, and this script
# repoints it at the target's tailnet IP.
#
# Sub-commands:
#   ./50-cutover-dns.sh check      show current state, change nothing
#   ./50-cutover-dns.sh tunnel     stop robco's connector, start the target's
#   ./50-cutover-dns.sh tailnet    repoint design.bgunnarsson.dev
#   ./50-cutover-dns.sh rollback   put the connector back on robco
. "$(dirname "$0")/lib.sh"
load_hosts
need curl; need jq

API="https://api.cloudflare.com/client/v4"
cf() {
  local m="$1" p="$2" b="${3:-}"
  if [ "${DRY_RUN:-0}" = "1" ] && [ "$m" != "GET" ]; then
    echo "  [dry-run] $m $p" >&2; echo '{"success":true,"result":{}}'; return
  fi
  if [ -n "$b" ]; then
    curl -sS -X "$m" "$API$p" -H "Authorization: Bearer $CF_API_TOKEN" \
      -H "Content-Type: application/json" --data "$b"
  else
    curl -sS -X "$m" "$API$p" -H "Authorization: Bearer $CF_API_TOKEN"
  fi
}

TAILNET_HOST="design.bgunnarsson.dev"

cmd_check() {
  step "Tunnel $CF_TUNNEL_ID ingress"
  cf GET "/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$CF_TUNNEL_ID/configurations" \
    | jq -r '.result.config.ingress[] | "    \(.hostname // "(fallback)") -> \(.service)"'

  step "Active connectors"
  cf GET "/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$CF_TUNNEL_ID/connections" \
    | jq -r '.result[]? | "    \(.id[0:8])  opened \(.opened_at)  \(.origin_ip)"'
  c_warn "exactly one connector should be live after cutover; two means split traffic"

  step "$TAILNET_HOST"
  local zid; zid=$(cf GET "/zones?name=bgunnarsson.dev" | jq -r '.result[0].id')
  cf GET "/zones/$zid/dns_records?name=$TAILNET_HOST" \
    | jq -r '.result[] | "    \(.type) \(.name) -> \(.content)  proxied=\(.proxied)"'
}

cmd_tunnel() {
  : "${TARGET_HOST:?set TARGET_HOST}"
  [ -f "$SECRETS_DIR/cloudflared.env" ] || die "secrets/cloudflared.env missing — run 10-collect-secrets.sh"
  confirm "Stop cloudflared on $SOURCE_HOST and start it on $TARGET_HOST? Public sites will blip." || exit 1

  step "Installing the tunnel token on $TARGET_HOST"
  scp -P "${TARGET_SSH_PORT:-22}" -q "$SECRETS_DIR/cloudflared.env" \
      "${TARGET_SSH_USER:+$TARGET_SSH_USER@}$TARGET_HOST:/tmp/cf.env"
  # Same unit robco uses: token mode, so the ingress config stays in Cloudflare
  # rather than a local config.yml. Nothing about the tunnel itself changes —
  # only which machine dials out.
  ssh_target 'sudo install -d -m 750 /etc/cloudflared \
    && sudo install -m 600 /tmp/cf.env /etc/cloudflared/env && rm -f /tmp/cf.env \
    && printf "%s\n" \
      "[Unit]" "Description=Cloudflare Tunnel" "After=network-online.target" "Wants=network-online.target" \
      "" "[Service]" "Type=simple" "EnvironmentFile=/etc/cloudflared/env" \
      "ExecStart=/usr/bin/cloudflared --no-autoupdate tunnel run" "Restart=always" "RestartSec=5s" \
      "" "[Install]" "WantedBy=multi-user.target" \
      | sudo tee /etc/systemd/system/cloudflared.service >/dev/null \
    && sudo systemctl daemon-reload'
  c_ok "unit installed"

  step "Stopping the connector on $SOURCE_HOST"
  run_source 'sudo systemctl disable --now cloudflared' || c_warn "could not stop it — do it by hand"
  c_ok "robco connector down"

  step "Starting the connector on $TARGET_HOST"
  ssh_target 'sudo systemctl enable --now cloudflared'
  sleep 5
  ssh_target 'systemctl is-active cloudflared' | sed 's/^/    /'
  cmd_check
}

cmd_tailnet() {
  : "${TARGET_TAILSCALE_IP:?set TARGET_TAILSCALE_IP in config/hosts.env}"
  step "Repointing $TAILNET_HOST -> $TARGET_TAILSCALE_IP"
  local zid rec
  zid=$(cf GET "/zones?name=bgunnarsson.dev" | jq -r '.result[0].id')
  [ -n "$zid" ] && [ "$zid" != "null" ] || die "zone bgunnarsson.dev not found — check token scopes"
  rec=$(cf GET "/zones/$zid/dns_records?name=$TAILNET_HOST&type=A" | jq -r '.result[0].id // empty')
  # proxied MUST stay false: a tailnet IP is unroutable from Cloudflare's edge,
  # and proxying it would also put a private app back on the public internet.
  local body
  body=$(jq -n --arg n "$TAILNET_HOST" --arg c "$TARGET_TAILSCALE_IP" \
    '{type:"A", name:$n, content:$c, proxied:false, ttl:60}')
  if [ -n "$rec" ]; then
    cf PUT "/zones/$zid/dns_records/$rec" "$body" | jq -e '.success' >/dev/null \
      && c_ok "updated" || die "update failed"
  else
    cf POST "/zones/$zid/dns_records" "$body" | jq -e '.success' >/dev/null \
      && c_ok "created" || die "create failed"
  fi
  c_warn "$TAILNET_HOST stays tailnet-only — never add it to the tunnel ingress"
}

cmd_rollback() {
  confirm "Move the connector back to $SOURCE_HOST?" || exit 1
  ssh_target 'sudo systemctl disable --now cloudflared' || true
  run_source 'sudo systemctl enable --now cloudflared'
  c_ok "connector back on $SOURCE_HOST"
  cmd_check
}

case "${1:-check}" in
  check)    cmd_check ;;
  tunnel)   cmd_tunnel ;;
  tailnet)  cmd_tailnet ;;
  rollback) cmd_rollback ;;
  *) die "usage: $0 {check|tunnel|tailnet|rollback}" ;;
esac
