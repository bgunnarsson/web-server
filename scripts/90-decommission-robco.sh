#!/usr/bin/env bash
# 90-decommission-robco.sh — stop robco serving websites, leaving it clean for
# use as a remote dev machine.
#
# DESTRUCTIVE in its later phases. It runs in stages and stops between them, so
# you can wait for the target to prove itself before deleting anything.
#
#   ./90-decommission-robco.sh stop     stop containers, leave all data (reversible)
#   ./90-decommission-robco.sh archive  final backup, then remove swarm + dokploy
#   ./90-decommission-robco.sh purge    delete volumes and images  (NOT reversible)
#
# Run ON robco.
. "$(dirname "$0")/lib.sh"
load_hosts
require_source

cmd_stop() {
  confirm "Stop cloudflared, Traefik and all site containers on $(myhostname)?" || exit 1
  step "cloudflared"
  if systemctl is-active -q cloudflared; then
    sudo systemctl disable --now cloudflared && c_ok "stopped and disabled"
  else
    c_ok "already stopped (moved to the target at cutover)"
  fi
  step "Site containers"
  for d in $(robco_projects); do
    # By label rather than `docker compose -p`, which wants the compose file.
    ids=$(docker ps -q --filter "label=com.docker.compose.project=$d")
    if [ -n "$ids" ]; then docker stop $ids >/dev/null && c_ok "$d stopped"
    else c_warn "$d: nothing to stop"; fi
  done
  step "Traefik"
  docker stop dokploy-traefik >/dev/null 2>&1 && c_ok "stopped" || c_warn "already stopped"
  echo
  c_ok "robco no longer serves anything. Data is untouched — 'archive' is the next stage."
}

cmd_archive() {
  step "Remove robco from Dokploy first"
  c_warn "In the Dokploy panel on ncr, confirm every app now targets the new server,"
  c_warn "then delete robco from the list of remote servers. Otherwise a redeploy there"
  c_warn "would bring the old sites back up here."
  confirm "Is robco removed from Dokploy?" || exit 1

  step "Final backup before anything is removed"
  # `stop` took postgres down with everything else; pg_dump needs it.
  pg=robco-design-llggv8-penpot-postgres-1
  docker start "$pg" >/dev/null
  until docker exec "$pg" pg_isready -U penpot >/dev/null 2>&1; do sleep 1; done
  "$REPO_ROOT/scripts/11-backup-volumes.sh"
  docker stop "$pg" >/dev/null
  confirm "Leave the docker swarm and remove Dokploy's state?" || exit 1
  step "Swarm"
  # A single-node swarm exists only because Dokploy's remote-server setup made
  # one. A dev box does not need it; leaving closes the 2377/7946 listeners.
  docker swarm leave --force >/dev/null 2>&1 && c_ok "left swarm" || c_warn "not in a swarm"
  step "Dokploy state"
  sudo mv /etc/dokploy "/etc/dokploy.retired-$(date +%Y%m%d)" \
    && c_ok "moved to /etc/dokploy.retired-* (delete it once you are sure)"
  step "Containers and networks"
  docker container prune -f >/dev/null && c_ok "stopped containers removed"
  docker network prune -f  >/dev/null && c_ok "unused networks removed"
  echo
  c_ok "Dokploy and swarm are gone. Volumes and images still hold ~2.1 GB + images."
  c_warn "copy $BACKUP_DIR off robco before running 'purge'"
}

cmd_purge() {
  c_warn "This deletes the binbox and penpot volumes permanently."
  c_warn "Confirm first that the target has the data:  scripts/60-verify.sh"
  confirm "Really delete all volumes and unused images on $(myhostname)?" || exit 1
  step "Volumes"
  for v in robco-binbox-odjv6q_binbox-data robco-design-llggv8_penpot_postgres_v15 robco-design-llggv8_penpot_assets; do
    docker volume rm "$v" >/dev/null 2>&1 && c_ok "removed $v" || c_warn "$v: already gone"
  done
  step "Images and build cache"
  docker image prune -af >/dev/null && c_ok "images pruned"
  docker builder prune -af >/dev/null && c_ok "build cache pruned"
  df -h / | sed 's/^/    /'
  echo
  c_ok "robco is now a clean dev machine. See docs/07-repurpose-robco.md for what to keep."
}

case "${1:-}" in
  stop)    cmd_stop ;;
  archive) cmd_archive ;;
  purge)   cmd_purge ;;
  *) die "usage: $0 {stop|archive|purge}  — run them in that order" ;;
esac
