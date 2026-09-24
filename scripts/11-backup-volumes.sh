#!/usr/bin/env bash
# 11-backup-volumes.sh — snapshot all persistent state from robco.
#
#   scripts/11-backup-volumes.sh            # live snapshot; apps keep running
#   scripts/11-backup-volumes.sh --freeze   # stop binbox + penpot first
#
# Use the plain form for a rehearsal. Use --freeze for the real move, right
# before cutover: anything written to robco after the snapshot would otherwise
# be lost. galdur.dev and penpot are down from the freeze until the tunnel moves
# (about ten minutes). `50-cutover-dns.sh rollback` restarts them on robco.
#
# Three things carry real data. Redeploying from Dokploy recreates everything else:
#   binbox-data          ~1.3 GB  two SQLite DBs + ~6400 downloaded card images
#   penpot_postgres_v15  ~69 MB   the design database
#   penpot_assets        ~4.6 MB  uploaded files
#
# Neither database is copied as raw files. SQLite goes through `.backup` (a
# consistent online copy, WAL included) and Postgres through `pg_dump`, so the
# snapshot is sound even without --freeze.
#
# Writes to backups/ (gitignored). Run on robco.
. "$(dirname "$0")/lib.sh"
load_hosts
require_source

FREEZE=0
[ "${1:-}" = "--freeze" ] && FREEZE=1

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$BACKUP_DIR/$STAMP"
mkdir -p "$OUT"

V_BINBOX="${V_BINBOX:-robco-binbox-odjv6q_binbox-data}"
V_ASSETS="${V_ASSETS:-robco-design-llggv8_penpot_assets}"
P_BINBOX="${V_BINBOX%_binbox-data}"
P_PENPOT="${V_ASSETS%_penpot_assets}"
PG_CONTAINER="${PG_CONTAINER:-$P_PENPOT-penpot-postgres-1}"

if [ "$FREEZE" = 1 ]; then
  step "Freezing binbox and penpot on robco"
  confirm "Stop galdur.dev and penpot on $(myhostname) until cutover?" || exit 1
  ids=$(docker ps -q --filter "label=com.docker.compose.project=$P_BINBOX")
  [ -n "$ids" ] && docker stop $ids >/dev/null
  c_ok "binbox stopped"
  # Everything but postgres, which pg_dump needs.
  ids=$(docker ps --filter "label=com.docker.compose.project=$P_PENPOT" --format '{{.ID}} {{.Names}}' \
        | grep -v penpot-postgres | cut -d' ' -f1)
  [ -n "$ids" ] && docker stop $ids >/dev/null
  c_ok "penpot stopped (postgres left up for the dump)"
fi

step "binbox SQLite databases -> consistent copies"
# sqlite3 lives in the alpine repo; .backup respects the WAL and produces a
# single self-contained file, so the -wal/-shm siblings are not needed.
docker run --rm -v "$V_BINBOX":/d:ro -v "$OUT":/out alpine sh -c '
  apk add --no-cache sqlite >/dev/null 2>&1
  for db in binbox catalog; do
    sqlite3 "file:/d/$db.db?mode=ro" ".backup /out/$db.db" && echo "    backed up $db.db"
  done'
c_ok "binbox.db + catalog.db"

step "binbox images -> tar"
docker run --rm -v "$V_BINBOX":/d:ro -v "$OUT":/out alpine \
  tar -C /d -czf /out/binbox-images.tar.gz images
c_ok "binbox-images.tar.gz"

step "penpot postgres -> pg_dump"
# Custom format (-Fc): compressed, and restorable into any PG 15+ regardless of
# how the target's data directory was initialised.
docker exec "$PG_CONTAINER" pg_dump -U penpot -d penpot -Fc > "$OUT/penpot.dump"
# Row count, so the restore can prove the data arrived.
docker exec "$PG_CONTAINER" psql -U penpot -d penpot -tAc 'select count(*) from file' > "$OUT/penpot.files"
c_ok "penpot.dump ($(du -h "$OUT/penpot.dump" | cut -f1), $(cat "$OUT/penpot.files") files)"

step "penpot assets -> tar"
docker run --rm -v "$V_ASSETS":/d:ro -v "$OUT":/out alpine \
  tar -C /d -czf /out/penpot-assets.tar.gz .
c_ok "penpot-assets.tar.gz"

step "Checksums"
( cd "$OUT" && sha256sum ./* > SHA256SUMS )
c_ok "SHA256SUMS"

# A pointer so later scripts do not have to guess which snapshot to use.
ln -sfn "$STAMP" "$BACKUP_DIR/latest"

echo
c_ok "snapshot: $OUT ($(du -sh "$OUT" | cut -f1))"
[ "$FREEZE" = 1 ] && c_warn "binbox and penpot are stopped on robco — next: scripts/30-restore-volumes.sh"
c_warn "these files contain all your application data — keep them off shared storage"
