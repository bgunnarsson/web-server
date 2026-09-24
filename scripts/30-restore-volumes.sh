#!/usr/bin/env bash
# 30-restore-volumes.sh — load a snapshot from 11-backup-volumes.sh into the
# target's named volumes. Run AFTER 40-deploy-stacks.sh has created the volumes
# but while the apps are stopped.
#
# Refuses to overwrite a non-empty volume unless FORCE=1.
. "$(dirname "$0")/lib.sh"
load_hosts

SNAP="${1:-$BACKUP_DIR/latest}"
[ -d "$SNAP" ] || die "no snapshot at $SNAP (run 11-backup-volumes.sh first)"
step "Verifying snapshot $SNAP"
( cd "$SNAP" && sha256sum -c SHA256SUMS --quiet ) || die "checksum mismatch — snapshot is corrupt"
c_ok "checksums good"

# Volume names on the target follow compose's <project>_<volume> convention.
V_BINBOX="${V_BINBOX:-binbox_binbox-data}"
V_PG_ASSETS="${V_PG_ASSETS:-penpot_penpot_assets}"
PG_CONTAINER="${PG_CONTAINER:-penpot-penpot-postgres-1}"

vol_empty() { [ -z "$(docker run --rm -v "$1":/d:ro alpine sh -c 'ls -A /d')" ]; }

guard() {
  local v="$1"
  docker volume inspect "$v" >/dev/null 2>&1 || die "volume $v does not exist — run 40-deploy-stacks.sh first"
  if ! vol_empty "$v" && [ "${FORCE:-0}" != "1" ]; then
    die "volume $v is not empty. Re-run with FORCE=1 to overwrite."
  fi
}

step "binbox data"
guard "$V_BINBOX"
docker run --rm -v "$V_BINBOX":/d -v "$SNAP":/in:ro alpine sh -c '
  cp /in/binbox.db /d/binbox.db
  cp /in/catalog.db /d/catalog.db
  rm -f /d/*.db-wal /d/*.db-shm
  tar -C /d -xzf /in/binbox-images.tar.gz
  # The binbox image runs as the node user, uid 1000.
  chown -R 1000:1000 /d'
c_ok "binbox.db, catalog.db, images/ restored"

step "penpot assets"
guard "$V_PG_ASSETS"
docker run --rm -v "$V_PG_ASSETS":/d -v "$SNAP":/in:ro alpine \
  sh -c 'tar -C /d -xzf /in/penpot-assets.tar.gz'
c_ok "assets restored"

step "penpot database"
# Postgres must be running (and only postgres) to load the dump. The backend is
# started afterwards so it never sees a half-restored schema.
docker compose -f "$REPO_ROOT/stacks/penpot/docker-compose.yml" up -d penpot-postgres
until docker exec "$PG_CONTAINER" pg_isready -U penpot >/dev/null 2>&1; do sleep 1; done
c_ok "postgres ready"
docker exec -i "$PG_CONTAINER" pg_restore -U penpot -d penpot --clean --if-exists --no-owner \
  < "$SNAP/penpot.dump" 2>&1 | grep -vE '^$' | tail -20 || true
c_ok "penpot database restored"

echo
c_ok "restore complete — now start the stacks: scripts/40-deploy-stacks.sh"
