#!/usr/bin/env bash
# Shared helpers. Source from the numbered scripts: . "$(dirname "$0")/lib.sh"
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
# Fields: name domains exposure stateful
sites() { grep -vE '^\s*#|^\s*$' "$REPO_ROOT/config/sites.tsv"; }

# myhostname — `hostname` is not installed on a minimal Arch system, and robco
# is one. Read the kernel value instead.
myhostname() { cat /proc/sys/kernel/hostname 2>/dev/null || echo unknown; }

# on_source — true when running on robco itself. Every script expects that.
on_source() { [ "$(myhostname)" = "${SOURCE_HOST:-robco}" ]; }
require_source() { on_source || die "run this on ${SOURCE_HOST:-robco}, not $(myhostname)"; }

# require_target — TARGET_HOST is set and is not robco. The restore wipes the
# volumes it finds, so pointing it at the source would destroy the live data.
require_target() {
  : "${TARGET_HOST:?set TARGET_HOST in config/hosts.env}"
  [ "${TARGET_HOST%%.*}" != "${SOURCE_HOST:-robco}" ] || die "TARGET_HOST is the source host"
}

# ssh_target — run a command on the target. Stdin passes through, so data can
# be streamed: `tar -cf - x | ssh_target 'tar -xf -'`.
ssh_target() {
  ssh -p "${TARGET_SSH_PORT:-22}" "${TARGET_SSH_USER:+$TARGET_SSH_USER@}$TARGET_HOST" "$@"
}
# ssh_target_tty — same, with a terminal, for commands that run sudo and may
# need to prompt for a password. Cannot carry stdin data.
ssh_target_tty() {
  ssh -t -p "${TARGET_SSH_PORT:-22}" "${TARGET_SSH_USER:+$TARGET_SSH_USER@}$TARGET_HOST" "$@"
}

# find_volume <suffix> — the one volume on the target whose name ends in
# _<suffix>. Dokploy names volumes <app-name>_<volume>, and the app name on the
# new server may differ from robco's, so the scripts look it up instead of
# assuming it. Fails unless exactly one matches.
find_volume() {
  local m n
  m=$(ssh_target "docker volume ls -q" | grep -E "_$1\$" || true)
  n=$(printf '%s' "$m" | grep -c . || true)
  [ "$n" -eq 1 ] || die "expected one volume *_$1 on $TARGET_HOST, found $n${m:+: $(echo $m)} — is the app deployed there? Set it explicitly to override."
  printf '%s\n' "$m"
}

# robco_projects — the compose project (= Dokploy app) names on robco.
robco_projects() { docker run --rm -v /etc/dokploy:/x:ro alpine ls /x/compose; }

confirm() {
  [ "${ASSUME_YES:-0}" = "1" ] && return 0
  local reply
  read -rp "$* [y/N] " reply
  [[ "$reply" =~ ^[Yy] ]]
}
