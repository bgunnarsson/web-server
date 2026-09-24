#!/usr/bin/env bash
# 11-backup-volumes.sh — snapshot all persistent state from robco.
#
# Three things carry real data. Everything else is rebuilt from source:
#   binbox-data          ~1.3 GB  two SQLite DBs + ~6400 downloaded card images
#   penpot_postgres_v15  ~69 MB   the design database
#   penpot_assets        ~4.6 MB  uploaded files
#
# SQLite and Postgres are both live while this runs, so neither is copied as raw
# files. SQLite goes through `.backup` (a consistent online copy, WAL included)
# and Postgres through `pg_dump`. A plain tar of either would risk a torn file.
#
# Writes to backups/ (gitignored). Run on robco.
. "$(dirname "$0")/lib.sh"
load_hosts

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$BACKUP_DIR/$STAMP"
mkdir -p "$OUT"

V_BINBOX="${V_BINBOX:-robco-binbox-odjv6q_binbox-data}"
V_PG="${V_PG:-robco-design-llggv8_penpot_postgres_v15}"
V_ASSETS="${V_ASSETS:-robco-design-llggv8_penpot_assets}"
PG_CONTAINER="${PG_CONTAINER:-robco-design-llggv8-penpot-postgres-1}"

step "binbox SQLite databases -> consistent copies"
# sqlite3 lives in the alpine repo; .backup respects the WAL and produces a
# single self-contained file, so the -wal/-shm siblings are not needed.
run_source "docker run --rm -v $V_BINBOX:/d:ro -v '$OUT':/out alpine sh -c '
  apk add --no-cache sqlite >/dev/null 2>&1
  for db in binbox catalog; do
    sqlite3 \"file:/d/\$db.db?mode=ro\" \".backup /out/\$db.db\" && echo \"  backed up \$db.db\"
  done'"
c_ok "binbox.db + catalog.db"

step "binbox images -> tar"
run_source "docker run --rm -v $V_BINBOX:/d:ro -v '$OUT':/out alpine \
  tar -C /d -czf /out/binbox-images.tar.gz images"
c_ok "binbox-images.tar.gz"

step "penpot postgres -> pg_dump"
# Custom format (-Fc): compressed, and restorable into any PG 15+ regardless of
# how the target's data directory was initialised.
run_source "docker exec $PG_CONTAINER pg_dump -U penpot -d penpot -Fc" > "$OUT/penpot.dump"
c_ok "penpot.dump ($(du -h "$OUT/penpot.dump" | cut -f1))"

step "penpot assets -> tar"
run_source "docker run --rm -v $V_ASSETS:/d:ro -v '$OUT':/out alpine \
  tar -C /d -czf /out/penpot-assets.tar.gz ."
c_ok "penpot-assets.tar.gz"

step "Checksums"
( cd "$OUT" && sha256sum ./* > SHA256SUMS )
c_ok "SHA256SUMS"

# A pointer so later scripts do not have to guess which snapshot to use.
ln -sfn "$STAMP" "$BACKUP_DIR/latest"

echo
c_ok "snapshot: $OUT"
du -sh "$OUT"
c_warn "these files contain all your application data — keep them off shared storage"
