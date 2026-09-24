#!/usr/bin/env bash
# 60-verify.sh — prove the migration actually worked. Read-only.
#
# Run it on the target (checks containers + local routing), from anywhere
# (checks the public URLs), or both. Exit code is non-zero if anything failed.
. "$(dirname "$0")/lib.sh"
load_hosts
rc=0

step "Containers"
if docker ps -q >/dev/null 2>&1; then
  while IFS=$'\t' read -r name repo domains port exposure stateful; do
    n=$(docker ps --filter "label=com.docker.compose.project=$name" -q | wc -l)
    if [ "$n" -gt 0 ]; then c_ok "$name: $n running"; else c_err "$name: nothing running"; rc=1; fi
  done < <(sites)
  docker ps --filter name=traefik -q | grep -q . && c_ok "traefik running" || { c_err "traefik not running"; rc=1; }
else
  c_warn "no local docker — skipping container checks"
fi

step "Origin routing (Host header straight at Traefik on :80)"
# This is the exact request cloudflared makes. A 404 here means Traefik has no
# router for that hostname; a 502 means the router exists but the app is down.
if curl -s -o /dev/null -m 3 http://localhost:80 2>/dev/null || [ $? -ne 7 ]; then
  while IFS=$'\t' read -r name repo domains port exposure stateful; do
    [ "$exposure" = "public" ] || continue
    h="${domains%%,*}"
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 -H "Host: $h" http://localhost/ || echo 000)
    case "$code" in
      200|301|302) c_ok  "$h -> $code" ;;
      *)           c_err "$h -> $code"; rc=1 ;;
    esac
  done < <(sites)
else
  c_warn "nothing on localhost:80 — run this on the target for origin checks"
fi

step "Public URLs (through Cloudflare)"
while IFS=$'\t' read -r name repo domains port exposure stateful; do
  [ "$exposure" = "public" ] || continue
  for h in ${domains//,/ }; do
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 15 "https://$h/" || echo 000)
    case "$code" in
      200|301|302) c_ok  "https://$h -> $code" ;;
      000)         c_err "https://$h -> no response"; rc=1 ;;
      *)           c_err "https://$h -> $code"; rc=1 ;;
    esac
  done
done < <(sites)

step "Tailnet-only hostname"
h=design.bgunnarsson.dev
ip=$(dig +short A "$h" 2>/dev/null | head -1)
if [ -n "$ip" ]; then
  case "$ip" in
    100.*) c_ok "$h -> $ip (tailnet range, DNS-only as intended)" ;;
    *)     c_err "$h -> $ip is NOT a tailnet address — it may be publicly exposed"; rc=1 ;;
  esac
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 15 "https://$h/" || echo 000)
  [ "$code" = "200" ] && c_ok "reachable over the tailnet ($code)" \
    || c_warn "got $code — expected unless you are on the tailnet"
else
  c_warn "no A record for $h"
fi

step "Certificates"
for h in galdur.dev design.bgunnarsson.dev; do
  exp=$(echo | timeout 10 openssl s_client -servername "$h" -connect "$h:443" 2>/dev/null \
        | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
  [ -n "$exp" ] && c_ok "$h expires $exp" || c_warn "$h: could not read certificate"
done

step "Tunnel connectors"
if [ -n "${CF_API_TOKEN:-}" ]; then
  n=$(curl -sS "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$CF_TUNNEL_ID/connections" \
      -H "Authorization: Bearer $CF_API_TOKEN" | jq '[.result[]?] | length')
  case "$n" in
    1) c_ok "exactly 1 connector" ;;
    0) c_err "no connector — public sites are down"; rc=1 ;;
    *) c_err "$n connectors — traffic is split between two machines"; rc=1 ;;
  esac
fi

step "Data spot-checks"
if docker ps --format '{{.Names}}' | grep -q '^binbox-binbox-1$'; then
  docker exec binbox-binbox-1 node -e "
    const s=require('fs').statSync('/app/data/catalog.db');
    console.log('    catalog.db', (s.size/1048576).toFixed(0)+' MB');
    require('fs').readdir('/app/data/images',(e,f)=>console.log('    images', f?f.length:0));" 2>/dev/null \
    || c_warn "could not inspect binbox data"
fi
if docker ps --format '{{.Names}}' | grep -q 'penpot-postgres'; then
  docker exec "$(docker ps --format '{{.Names}}' | grep penpot-postgres | head -1)" \
    psql -U penpot -d penpot -tAc "select 'files='||count(*) from file" 2>/dev/null | sed 's/^/    /' \
    || c_warn "could not query penpot"
fi

echo
[ "$rc" -eq 0 ] && c_ok "all checks passed" || c_err "some checks failed"
exit "$rc"
