#!/usr/bin/env bash
# 00-preflight.sh — check both ends before anything is moved. Read-only.
. "$(dirname "$0")/lib.sh"
load_hosts

rc=0
step "Local tooling"
for t in ssh docker jq curl git tar; do
  if command -v "$t" >/dev/null 2>&1; then c_ok "$t"; else c_err "$t missing"; rc=1; fi
done
# rsync is convenient for copying the snapshot but not required — robco does not
# have it, and `tar | ssh` works just as well. See docs/04-migration-runbook.md.
for t in rsync; do
  command -v "$t" >/dev/null 2>&1 && c_ok "$t (optional)" || c_warn "$t not installed — use the tar|ssh fallback"
done

step "Source host ($SOURCE_HOST)"
if on_source; then
  c_ok "running on the source host directly"
else
  if ssh_source true 2>/dev/null; then c_ok "ssh reachable on :${SOURCE_SSH_PORT}"
  else c_err "cannot ssh to $SOURCE_HOST:${SOURCE_SSH_PORT}"; rc=1; fi
fi
if run_source 'docker ps -q >/dev/null 2>&1'; then c_ok "docker usable"; else c_err "docker not usable"; rc=1; fi

step "Target host (${TARGET_HOST:-<unset>})"
if [ -z "${TARGET_HOST:-}" ]; then
  c_warn "TARGET_HOST not set — fill it in config/hosts.env before step 20"
  rc=1
else
  if ssh_target true 2>/dev/null; then
    c_ok "ssh reachable on :${TARGET_SSH_PORT:-22}"
    ssh_target 'command -v docker >/dev/null' && c_ok "docker installed" || c_warn "docker not installed (20-provision-target.sh installs it)"
    ssh_target 'docker ps -q >/dev/null 2>&1' && c_ok "docker usable without sudo" || c_warn "user not in docker group yet"
    # 2.1 GB of volumes plus images and build caches; 20 GB is a safe floor.
    free_kb=$(ssh_target "df -Pk ${TARGET_ROOT%/*} 2>/dev/null | awk 'NR==2{print \$4}'" || echo 0)
    if [ "${free_kb:-0}" -ge 20971520 ]; then c_ok "$((free_kb/1048576)) GB free on target"
    else c_warn "only $((free_kb/1048576)) GB free — want 20 GB+ (volumes alone are ~2.1 GB)"; fi
    ssh_target 'command -v tailscale >/dev/null && tailscale status >/dev/null 2>&1' \
      && c_ok "tailscale up" || c_warn "tailscale not up (needed for penpot's tailnet-only hostname)"
  else
    c_err "cannot ssh to $TARGET_HOST:${TARGET_SSH_PORT:-22}"; rc=1
  fi
fi

step "Cloudflare API"
if [ -z "${CF_API_TOKEN:-}" ]; then
  c_err "CF_API_TOKEN not set in config/hosts.env"; rc=1
else
  if curl -sS "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$CF_TUNNEL_ID/configurations" \
       -H "Authorization: Bearer $CF_API_TOKEN" | jq -e '.success' >/dev/null; then
    c_ok "token can read the tunnel config"
  else
    c_err "token cannot read tunnel $CF_TUNNEL_ID — check scopes (Account:Cloudflare Tunnel:Edit)"; rc=1
  fi
fi

echo
[ "$rc" -eq 0 ] && c_ok "preflight passed" || c_warn "preflight found problems — fix them before continuing"
exit "$rc"
