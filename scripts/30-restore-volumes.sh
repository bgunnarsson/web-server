#!/usr/bin/env bash
# 30-restore-volumes.sh — load a snapshot from 11-backup-volumes.sh into the
# volumes Dokploy created on the target. Run on robco. The data is streamed over
# ssh, so nothing has to be copied to the target by hand.
#
#   scripts/30-restore-volumes.sh [snapshot-dir]    # default: backups/latest
#
# Deploy binbox and penpot to the target from Dokploy first. That creates their
# volumes (filled with empty starter data). This script finds the volumes,
# stops the apps, REPLACES the contents with the snapshot, and starts the apps.
# It asks before touching each app; ASSUME_YES=1 skips the prompts.
#
# Safe to repeat: every run wipes and reloads, so rehearse with a live snapshot
# and re-run with the frozen one at cutover.
#
# Volumes are found by suffix. To override: V_BINBOX=… V_PG=… V_ASSETS=…
. "$(dirname "$0")/lib.sh"
load_hosts
require_source
require_target

SNAP="${1:-$BACKUP_DIR/latest}"
[ -d "$SNAP" ] || die "no snapshot at $SNAP (run 11-backup-volumes.sh first)"
step "Verifying snapshot $(readlink -f "$SNAP")"
( cd "$SNAP" && sha256sum -c SHA256SUMS --quiet ) || die "checksum mismatch — snapshot is corrupt"
c_ok "checksums good"

step "Finding the volumes on $TARGET_HOST"
V_BINBOX="${V_BINBOX:-$(find_volume binbox-data)}"
V_PG="${V_PG:-$(find_volume penpot_postgres_v15)}"
V_ASSETS="${V_ASSETS:-$(find_volume penpot_assets)}"
P_BINBOX="${V_BINBOX%_binbox-data}"
P_PENPOT="${V_ASSETS%_penpot_assets}"
c_ok "binbox: $V_BINBOX"
c_ok "penpot: $V_PG, $V_ASSETS"

# project_ids <project> — running container ids of a compose project.
project_ids() { ssh_target "docker ps -q --filter label=com.docker.compose.project=$1"; }

# ---- binbox -----------------------------------------------------------------
step "binbox"
ids=$(project_ids "$P_BINBOX")
[ -n "$ids" ] || die "binbox is not running on $TARGET_HOST — deploy it from Dokploy first"
confirm "Replace ALL binbox data on $TARGET_HOST ($V_BINBOX)?" || exit 1
ssh_target "docker stop $(echo $ids)" >/dev/null
c_ok "stopped"
# Files are handed to the container's uid, whatever the image uses: taken from
# the freshly deployed data if present, else from the volume root.
tar -C "$SNAP" -cf - binbox.db catalog.db binbox-images.tar.gz \
  | ssh_target "docker run --rm -i -v $V_BINBOX:/d alpine sh -c '
      set -e
      own=\$(stat -c %u:%g /d/binbox.db 2>/dev/null || stat -c %u:%g /d)
      find /d -mindepth 1 -delete
      tar -xf - -C /d
      tar -xzf /d/binbox-images.tar.gz -C /d && rm /d/binbox-images.tar.gz
      chown -R \$own /d
      echo \"    \$(ls /d/images | wc -l) images, owner \$own\"'"
c_ok "binbox.db, catalog.db, images/ restored"
ssh_target "docker start $(echo $ids)" >/dev/null
c_ok "started"

# ---- penpot -----------------------------------------------------------------
step "penpot"
all=$(ssh_target "docker ps --filter label=com.docker.compose.project=$P_PENPOT --format '{{.ID}} {{.Names}}'")
pg=$(grep penpot-postgres <<<"$all" | cut -d' ' -f1 || true)
others=$(grep -v penpot-postgres <<<"$all" | cut -d' ' -f1 | tr '\n' ' ' || true)
[ -n "$pg" ] || die "penpot's postgres is not running on $TARGET_HOST — deploy penpot from Dokploy first"
confirm "Replace ALL penpot data on $TARGET_HOST ($V_PG, $V_ASSETS)?" || exit 1
# Postgres stays up for the restore; everything that talks to it stops, so the
# backend never sees a half-restored schema.
[ -n "${others// }" ] && ssh_target "docker stop $others" >/dev/null
c_ok "stopped all but postgres"

# tar preserves the assets' numeric owner (uid 1001, penpot's user).
ssh_target "docker run --rm -i -v $V_ASSETS:/d alpine sh -c 'find /d -mindepth 1 -delete && tar -xzf - -C /d'" \
  < "$SNAP/penpot-assets.tar.gz"
c_ok "assets restored"

# Drop and recreate rather than pg_restore --clean: the fresh deploy has already
# run penpot's migrations, and restoring over them leaves duplicate objects.
ssh_target "docker exec $pg psql -U penpot -d postgres -v ON_ERROR_STOP=1 -q \
  -c 'DROP DATABASE IF EXISTS penpot WITH (FORCE)' -c 'CREATE DATABASE penpot OWNER penpot'"
ssh_target "docker exec -i $pg pg_restore -U penpot -d penpot --no-owner" < "$SNAP/penpot.dump" 2>&1 \
  | sed 's/^/    /' | tail -20 || true
got=$(ssh_target "docker exec $pg psql -U penpot -d penpot -tAc 'select count(*) from file'" || echo "?")
if [ -f "$SNAP/penpot.files" ]; then
  want=$(cat "$SNAP/penpot.files")
  [ "$got" = "$want" ] && c_ok "database restored ($got files, matches robco)" \
    || die "database has $got files, snapshot had $want — penpot left stopped; investigate before starting"
else
  c_ok "database restored ($got files)"
fi
[ -n "${others// }" ] && ssh_target "docker start $others" >/dev/null
c_ok "started"

echo
c_ok "restore complete — next: scripts/50-cutover-dns.sh tunnel"
