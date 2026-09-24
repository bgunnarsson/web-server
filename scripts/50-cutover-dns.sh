#!/usr/bin/env bash
# 50-cutover-dns.sh — move traffic from robco to the target. Run on robco.
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
#   ./50-cutover-dns.sh rollback   connector, apps and the tailnet record back to robco
. "$(dirname "$0")/lib.sh"
load_hosts
require_source
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
  c_warn "exactly one connector should be live; two means split traffic"

  step "$TAILNET_HOST"
  local zid; zid=$(cf GET "/zones?name=bgunnarsson.dev" | jq -r '.result[0].id')
  cf GET "/zones/$zid/dns_records?name=$TAILNET_HOST" \
    | jq -r '.result[] | "    \(.type) \(.name) -> \(.content)  proxied=\(.proxied)"'

  if [ -n "${CF_DOKPLOY_TUNNEL_ID:-}" ]; then
    step "Stale rules on the ncr 'dokploy' tunnel"
    local stale
    stale=$(cf GET "/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$CF_DOKPLOY_TUNNEL_ID/configurations" \
      | jq -r --arg h "$SOURCE_HOST" '.result.config.ingress[]? | select(.service | test("//" + $h + "[:/]|//" + $h + "$")) | "    \(.hostname) -> \(.service)"')
    if [ -n "$stale" ]; then
      printf '%s\n' "$stale"
      c_warn "these point at $SOURCE_HOST. DNS does not route to them today, but they will"
      c_warn "be wrong once robco is a dev box — edit or remove them in the Cloudflare dashboard"
    else
      c_ok "none point at $SOURCE_HOST"
    fi
  fi
}

# origin_ok — every public hostname answers through the target's Traefik, the
# exact request cloudflared will make there.
origin_ok() {
  local ok=0 h code
  while IFS=$'\t' read -r name domains exposure stateful; do
    [ "$exposure" = "public" ] || continue
    for h in ${domains//,/ }; do
      code=$(ssh_target "curl -s -o /dev/null -w '%{http_code}' -m 10 -H 'Host: $h' http://localhost/" </dev/null || echo 000)
      case "$code" in
        200|301|302|303|307|308) c_ok "$h -> $code" ;;
        *) c_err "$h -> $code"; ok=1 ;;
      esac
    done
  done < <(sites)
  return "$ok"
}

# robco_apps <start|stop> — every Dokploy app's containers on robco.
robco_apps() {
  local p ids
  for p in $(robco_projects); do
    ids=$(docker ps -aq --filter "label=com.docker.compose.project=$p")
    [ -n "$ids" ] && docker "$1" $ids >/dev/null && c_ok "$p: $1"
  done
  return 0
}

cmd_tunnel() {
  require_target
  ssh_target 'command -v cloudflared >/dev/null' || die "cloudflared is not installed on $TARGET_HOST"

  step "Origin check on $TARGET_HOST"
  if ! origin_ok; then
    [ "${FORCE:-0}" = 1 ] || die "the target does not serve every site yet. Fix it, or FORCE=1 to cut over anyway."
    c_warn "continuing because FORCE=1"
  fi

  confirm "Stop cloudflared on $SOURCE_HOST and start it on $TARGET_HOST? Public sites will blip." || exit 1

  step "Installing the tunnel token on $TARGET_HOST"
  # Straight from robco's file to the target, never written anywhere else.
  sudo cat /etc/cloudflared/env | ssh_target 'umask 077 && cat > /tmp/cf.env'
  # Same unit robco uses: token mode, so the ingress config stays in Cloudflare
  # rather than a local config.yml. Nothing about the tunnel itself changes —
  # only which machine dials out.
  ssh_target_tty 'sudo install -d -m 750 /etc/cloudflared \
    && sudo install -m 600 /tmp/cf.env /etc/cloudflared/env && rm -f /tmp/cf.env \
    && printf "%s\n" \
      "[Unit]" "Description=Cloudflare Tunnel" "After=network-online.target" "Wants=network-online.target" \
      "" "[Service]" "Type=simple" "EnvironmentFile=/etc/cloudflared/env" \
      "ExecStart=$(command -v cloudflared) --no-autoupdate tunnel run" "Restart=always" "RestartSec=5s" \
      "" "[Install]" "WantedBy=multi-user.target" \
      | sudo tee /etc/systemd/system/cloudflared.service >/dev/null \
    && sudo systemctl daemon-reload'
  c_ok "unit installed"

  step "Stopping the connector on $SOURCE_HOST"
  sudo systemctl disable --now cloudflared
  c_ok "robco connector down"

  step "Starting the connector on $TARGET_HOST"
  ssh_target_tty 'sudo systemctl enable --now cloudflared'
  sleep 5
  ssh_target 'systemctl is-active cloudflared' | sed 's/^/    /'
  cmd_check
}

# set_tailnet_record <ip> — point design.bgunnarsson.dev at a tailnet IP.
set_tailnet_record() {
  local ip="$1" zid rec body
  case "$ip" in 100.*) ;; *) die "$ip is not a tailnet address — refusing to publish $TAILNET_HOST there" ;; esac
  step "Repointing $TAILNET_HOST -> $ip"
  zid=$(cf GET "/zones?name=bgunnarsson.dev" | jq -r '.result[0].id')
  [ -n "$zid" ] && [ "$zid" != "null" ] || die "zone bgunnarsson.dev not found — check token scopes"
  rec=$(cf GET "/zones/$zid/dns_records?name=$TAILNET_HOST&type=A" | jq -r '.result[0].id // empty')
  # proxied MUST stay false: a tailnet IP is unroutable from Cloudflare's edge,
  # and proxying it would also put a private app back on the public internet.
  body=$(jq -n --arg n "$TAILNET_HOST" --arg c "$ip" \
    '{type:"A", name:$n, content:$c, proxied:false, ttl:60}')
  if [ -n "$rec" ]; then
    cf PUT "/zones/$zid/dns_records/$rec" "$body" | jq -e '.success' >/dev/null \
      && c_ok "updated" || die "update failed"
  else
    cf POST "/zones/$zid/dns_records" "$body" | jq -e '.success' >/dev/null \
      && c_ok "created" || die "create failed"
  fi
  c_warn "$TAILNET_HOST stays tailnet-only — never add it to a tunnel's ingress"
}

cmd_tailnet() {
  : "${TARGET_TAILSCALE_IP:?set TARGET_TAILSCALE_IP in config/hosts.env}"
  set_tailnet_record "$TARGET_TAILSCALE_IP"
}

cmd_rollback() {
  confirm "Move the connector, the apps and $TAILNET_HOST back to $SOURCE_HOST?" || exit 1
  step "Connector"
  if [ -n "${TARGET_HOST:-}" ]; then
    ssh_target_tty 'sudo systemctl disable --now cloudflared' || c_warn "could not stop it on $TARGET_HOST — do it by hand"
  fi
  sudo systemctl enable --now cloudflared
  c_ok "connector back on $SOURCE_HOST"
  step "Apps on $SOURCE_HOST"
  # --freeze stopped binbox and penpot; start everything that exists.
  robco_apps start
  set_tailnet_record "${SOURCE_TAILSCALE_IP:?set SOURCE_TAILSCALE_IP in config/hosts.env}"
  c_warn "anything written on $TARGET_HOST since the restore is NOT on robco"
  cmd_check
}

case "${1:-check}" in
  check)    cmd_check ;;
  tunnel)   cmd_tunnel ;;
  tailnet)  cmd_tailnet ;;
  rollback) cmd_rollback ;;
  *) die "usage: $0 {check|tunnel|tailnet|rollback}" ;;
esac
