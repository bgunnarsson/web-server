#!/usr/bin/env bash
# 40-deploy-stacks.sh — clone each application repo and bring its stack up.
#
# Run ON the target, from a checkout of this repo, with secrets/ present.
#
#   scripts/40-deploy-stacks.sh              # all sites
#   scripts/40-deploy-stacks.sh binvim       # just one
#   NO_START=1 scripts/40-deploy-stacks.sh   # clone + build, do not start
#
# Order matters for the stateful stacks: build and create the volumes here with
# NO_START=1, run 30-restore-volumes.sh, then re-run this without NO_START.
. "$(dirname "$0")/lib.sh"
load_hosts

[ -f "$SECRETS_DIR/github.env" ] && . "$SECRETS_DIR/github.env"

docker network inspect proxy >/dev/null 2>&1 || die "'proxy' network missing — run 20-provision-target.sh"

only="${1:-}"
while IFS=$'\t' read -r name repo domains port exposure stateful; do
  [ -n "$only" ] && [ "$only" != "$name" ] && continue
  step "$name  ($domains)"
  d="$REPO_ROOT/stacks/$name"
  [ -d "$d" ] || { c_err "no stack directory $d"; continue; }

  # --- source ---------------------------------------------------------------
  if [ "$repo" = "-" ]; then
    c_ok "no repo to clone (upstream images only)"
  else
    url="https://github.com/$repo.git"
    # Auth goes in the URL only for the clone/fetch call, never into .git/config
    # — that is exactly the mistake Dokploy made (expired ghs_ tokens are still
    # sitting in every repo on robco).
    auth_url="$url"
    [ -n "${GITHUB_TOKEN:-}" ] && auth_url="https://x-access-token:${GITHUB_TOKEN}@github.com/$repo.git"
    if [ -d "$d/src/.git" ]; then
      git -C "$d/src" fetch --depth 1 "$auth_url" main -q && git -C "$d/src" reset --hard FETCH_HEAD -q
      c_ok "updated to $(git -C "$d/src" rev-parse --short HEAD)"
    else
      git clone --depth 1 -b main "$auth_url" "$d/src" -q || { c_err "clone failed — check GITHUB_TOKEN"; continue; }
      git -C "$d/src" remote set-url origin "$url"   # strip the token back out
      c_ok "cloned at $(git -C "$d/src" rev-parse --short HEAD)"
    fi
  fi

  # --- secrets --------------------------------------------------------------
  if [ -f "$SECRETS_DIR/$name.env" ]; then
    cp "$SECRETS_DIR/$name.env" "$d/.env"; chmod 600 "$d/.env"
    c_ok ".env in place"
  elif [ -f "$d/.env.example" ]; then
    c_warn "no secrets/$name.env — this stack needs one (see .env.example)"
  fi

  # --- build & run ----------------------------------------------------------
  docker compose -f "$d/docker-compose.yml" --project-directory "$d" -p "$name" build -q \
    && c_ok "built"
  if [ "${NO_START:-0}" = "1" ]; then
    # `create` makes the named volumes without starting anything, so the
    # restore step has somewhere to put the data.
    docker compose -f "$d/docker-compose.yml" --project-directory "$d" -p "$name" create
    c_warn "created but not started (NO_START=1)"
  else
    docker compose -f "$d/docker-compose.yml" --project-directory "$d" -p "$name" up -d
    c_ok "up"
  fi
done < <(sites)

echo
c_ok "done — verify with scripts/60-verify.sh"
