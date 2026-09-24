#!/usr/bin/env bash
# 60-verify.sh — prove the migration actually worked. Read-only.
# Run on robco. Exit code is non-zero if anything failed.
. "$(dirname "$0")/lib.sh"
load_hosts
require_source
require_target
rc=0
bad() { c_err "$*"; rc=1; }

step "Apps on $TARGET_HOST"
labels=$(ssh_target 'docker ps --format "{{.Labels}}"')
while IFS=$'\t' read -r name domains exposure stateful; do
  for h in ${domains//,/ }; do
    grep -qF "Host(\`$h\`)" <<<"$labels" && c_ok "$h has a running container" || bad "$h: no running container"
  done
done < <(sites)
ssh_target 'docker ps --format "{{.Names}}"' | grep -qx dokploy-traefik \
  && c_ok "dokploy-traefik running" || bad "dokploy-traefik not running"

step "Origin routing (Host header at the target's Traefik on :80)"
# The exact request cloudflared makes. 404 = Traefik has no router for that
# hostname; 502 = the router exists but the app is down.
while IFS=$'\t' read -r name domains exposure stateful; do
  [ "$exposure" = "public" ] || continue
  h="${domains%%,*}"
  code=$(ssh_target "curl -s -o /dev/null -w '%{http_code}' -m 10 -H 'Host: $h' http://localhost/" </dev/null || echo 000)
  case "$code" in
    200|301|302|303|307|308) c_ok "$h -> $code" ;;
    *) bad "$h -> $code" ;;
  esac
done < <(sites)

step "Public URLs (through Cloudflare)"
while IFS=$'\t' read -r name domains exposure stateful; do
  [ "$exposure" = "public" ] || continue
  for h in ${domains//,/ }; do
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 15 "https://$h/" || echo 000)
    case "$code" in
      200|301|302|303|307|308) c_ok "https://$h -> $code" ;;
      000) bad "https://$h -> no response" ;;
      *)   bad "https://$h -> $code" ;;
    esac
  done
done < <(sites)

step "Tunnel connectors"
if [ -n "${CF_API_TOKEN:-}" ]; then
  conns=$(curl -sS "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$CF_TUNNEL_ID/connections" \
      -H "Authorization: Bearer $CF_API_TOKEN")
  n=$(jq '[.result[]?] | length' <<<"$conns")
  case "$n" in
    1) c_ok "exactly 1 connector ($(jq -r '.result[0].origin_ip' <<<"$conns"))" ;;
    0) bad "no connector — public sites are down" ;;
    *) bad "$n connectors — traffic is split between two machines" ;;
  esac
  systemctl is-active -q cloudflared && bad "cloudflared is still running on $SOURCE_HOST" \
    || c_ok "cloudflared stopped on $SOURCE_HOST"
  ssh_target 'systemctl is-active -q cloudflared' && c_ok "cloudflared running on $TARGET_HOST" \
    || bad "cloudflared not running on $TARGET_HOST"
else
  c_warn "CF_API_TOKEN unset — skipping connector count"
fi

step "Tailnet-only hostname"
h=design.bgunnarsson.dev
ip=$(getent ahostsv4 "$h" 2>/dev/null | awk 'NR==1{print $1}')
case "$ip" in
  "") c_warn "$h does not resolve" ;;
  "${TARGET_TAILSCALE_IP:-x}") c_ok "$h -> $ip (the target, DNS-only as intended)" ;;
  100.*) bad "$h -> $ip — a tailnet address, but not the target's (${TARGET_TAILSCALE_IP:-unset}). Run 50-cutover-dns.sh tailnet" ;;
  *) bad "$h -> $ip is NOT a tailnet address — it may be publicly exposed" ;;
esac
# robco is on the tailnet, so this is a real end-to-end test of the cert too.
code=$(curl -s -o /dev/null -w '%{http_code}' -m 15 "https://$h/" || echo 000)
case "$code" in
  200|301|302) c_ok "https://$h -> $code over the tailnet, valid certificate" ;;
  000) bad "https://$h -> no response or bad certificate (check: docker logs dokploy-traefik 2>&1 | grep -i acme)" ;;
  *)   bad "https://$h -> $code" ;;
esac

step "Data"
snap="$BACKUP_DIR/latest"
if v=$(find_volume binbox-data 2>/dev/null); then
  ssh_target "docker run --rm -v $v:/d:ro alpine sh -c 'echo \"    binbox: \$(du -sh /d | cut -f1), \$(ls /d/images 2>/dev/null | wc -l) images\"'"
else
  bad "no single *_binbox-data volume on $TARGET_HOST (none, or more than one)"
fi
pg=$(ssh_target 'docker ps --format "{{.ID}} {{.Names}}"' | grep penpot-postgres | cut -d' ' -f1 | head -1 || true)
if [ -n "$pg" ]; then
  got=$(ssh_target "docker exec $pg psql -U penpot -d penpot -tAc 'select count(*) from file'" || echo "?")
  if [ -f "$snap/penpot.files" ]; then
    [ "$got" = "$(cat "$snap/penpot.files")" ] && c_ok "penpot: $got files, matches the snapshot" \
      || bad "penpot: $got files, snapshot had $(cat "$snap/penpot.files")"
  else
    c_ok "penpot: $got files"
  fi
else
  bad "penpot postgres not running on $TARGET_HOST"
fi
c_warn "also log in to galdur.dev and open a penpot file — counts are not proof"

echo
[ "$rc" -eq 0 ] && c_ok "all checks passed" || c_err "some checks failed"
exit "$rc"
