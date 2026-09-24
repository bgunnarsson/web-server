#!/usr/bin/env bash
# Shared helpers. Source from the numbered scripts: . "$(dirname "$0")/lib.sh"
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS_DIR="$REPO_ROOT/secrets"
BACKUP_DIR="${BACKUP_DIR:-$REPO_ROOT/backups}"

c_ok()   { printf '\033[32m  ✓\033[0m %s\n' "$*"; }
c_warn() { printf '\033[33m  !\033[0m %s\n' "$*"; }
c_err()  { printf '\033[31m  ✗\033[0m %s\n' "$*" >&2; }
step()   { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die()    { c_err "$*"; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }

# load_hosts — read config/hosts.env, failing loudly if it was never created.
load_hosts() {
  local f="$REPO_ROOT/config/hosts.env"
  [ -f "$f" ] || die "config/hosts.env not found. Copy config/hosts.env.example and fill it in."
  set -a; . "$f"; set +a
}

# sites — emit the registry as TSV rows, comments and blanks stripped.
# Fields: name repo domains port exposure stateful
sites() { grep -vE '^\s*#|^\s*$' "$REPO_ROOT/config/sites.tsv"; }

# site_field <name> <1-based field index>
site_field() {
  sites | awk -F'\t' -v n="$1" -v f="$2" '$1==n {print $f}'
}

# ssh_target / ssh_source — run a command on the far end.
ssh_target() {
  : "${TARGET_HOST:?TARGET_HOST not set in config/hosts.env}"
  ssh -p "${TARGET_SSH_PORT:-22}" "${TARGET_SSH_USER:+$TARGET_SSH_USER@}$TARGET_HOST" "$@"
}
ssh_source() {
  : "${SOURCE_HOST:?SOURCE_HOST not set in config/hosts.env}"
  ssh -p "${SOURCE_SSH_PORT:-22}" "$SOURCE_HOST" "$@"
}

# myhostname — `hostname` is not installed on a minimal Arch system, and robco
# is one. Read the kernel value instead.
myhostname() { cat /proc/sys/kernel/hostname 2>/dev/null || echo unknown; }

# on_source — true when this script is running on robco itself, in which case
# the "source" scripts act locally instead of over ssh.
on_source() { [ "$(myhostname)" = "${SOURCE_HOST:-robco}" ]; }

# run_source — run locally if we're on the source box, else over ssh.
run_source() { if on_source; then bash -c "$*"; else ssh_source "$*"; fi; }

confirm() {
  [ "${ASSUME_YES:-0}" = "1" ] && return 0
  local reply
  read -rp "$* [y/N] " reply
  [[ "$reply" =~ ^[Yy] ]]
}
