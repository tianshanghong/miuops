#!/usr/bin/env bash
# Deploy ONE fleet server's stacks over SSH. Invoked by the reusable deploy
# workflow's matrix job, which binds `environment: <server>` so the SSH secrets
# below belong to exactly this one server (no other server's key is in scope).
#
# Inputs (environment):
#   SERVER             server name = the fleet/stacks/<server> directory name.
#   SSH_HOST           target host (required).
#   SSH_USER           SSH user (required).
#   SSH_PRIVATE_KEY    deploy private key, PEM (required).
#   SSH_PORT           SSH port (default 22).
#   SSH_KNOWN_HOSTS    independently verified known_hosts (required).
#   STACKS_DIR         repo path prefix for stacks (default fleet/stacks).
#   REMOTE_STACKS_DIR  destination on the server (default /opt/stacks).
#   ONLY_STACK         (manual dispatch) bring up only this stack dir within the
#                      server; blank = every stack. Validated like SERVER.
#   FORCE_RECREATE     (manual dispatch) "true" adds `--force-recreate` to
#                      `docker compose up` so a container is recreated even when
#                      its image + config are unchanged (re-runs its entrypoint).
#
# By design the rsync excludes .env and any *.env: every *.env is treated as a
# host-provisioned secret (the shared app env is decrypted + placed at setup,
# never shipped by deploy), so a repo-managed *.env is never transferred and an
# on-host *.env is never deleted by --delete.
#
# Security: SERVER comes from an operator-controlled directory name, so it is
# re-validated here (second gate after discover) and only ever used as a path
# segment / argument, never concatenated into a shell command. The private key
# is written to a private temp dir and removed on exit. Secrets are read from
# the environment, never interpolated into a logged command; no ssh/rsync
# verbosity, no `set -x`.

export LC_ALL=C
set -euo pipefail

err()  { printf '::error::%s\n' "$*" >&2; exit 1; }
note() { printf '::notice::%s\n'  "$*"; }

NAME_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'
SERVER="${SERVER:?SERVER is required}"
[[ "$SERVER" =~ $NAME_RE ]] || err "Refusing to deploy: invalid server name '${SERVER}'"

# Optional manual-dispatch targeting (both empty on a normal push deploy).
# ONLY_STACK is operator-controlled, so it is validated with the same allowlist
# as SERVER and only ever compared as data (never concatenated into a command).
# FORCE_RECREATE is constrained to the two literals it is later tested against.
ONLY_STACK="${ONLY_STACK:-}"
if [ -n "$ONLY_STACK" ]; then
  case "$ONLY_STACK" in .|..) err "Refusing to deploy: invalid stack name '${ONLY_STACK}'";; esac
  [[ "$ONLY_STACK" =~ $NAME_RE ]] || err "Refusing to deploy: invalid stack name '${ONLY_STACK}'"
fi
case "${FORCE_RECREATE:=false}" in true|false) ;; *) err "FORCE_RECREATE must be 'true' or 'false', got '${FORCE_RECREATE}'";; esac

# A server with no stack directory is a clean skip (exit 0) -- check this BEFORE
# the SSH secrets, so a server removed from the fleet (or one whose Environment
# has no secrets) is a no-op, not a "No SSH_HOST" failure. discover lists every
# changed server including deletions, so a removed stack dir would otherwise red
# the run with a misleading secrets error. EXCEPTION: a targeted single-stack
# dispatch (ONLY_STACK set) to a serverless server is an operator error, not a
# removed-server skip -- fail loudly.
STACKS_DIR="${STACKS_DIR:-fleet/stacks}"; STACKS_DIR="${STACKS_DIR%/}"
src="${GITHUB_WORKSPACE:-.}/${STACKS_DIR}/${SERVER}"
if [ ! -d "$src" ]; then
  [ -z "$ONLY_STACK" ] || err "Cannot target stack '${ONLY_STACK}': server '${SERVER}' has no stacks (${STACKS_DIR}/${SERVER} absent)."
  note "No stacks for '${SERVER}' (${STACKS_DIR}/${SERVER} absent) — nothing to deploy."; exit 0
fi
# A targeted single-stack dispatch must name a stack that exists in the repo; fail
# fast (before SSH / any host action) rather than syncing nothing and exiting green.
if [ -n "$ONLY_STACK" ] && [ ! -d "${src}/${ONLY_STACK}" ]; then
  err "Requested stack '${ONLY_STACK}' does not exist under ${STACKS_DIR}/${SERVER} in the repo."
fi

# Fail fast on missing secrets BEFORE any network action, naming the server. A
# typo'd Environment resolves to empty secrets (no cross-server fallback exists),
# so this fails CLOSED — it can never reuse another server's key.
[ -n "${SSH_HOST:-}" ]        || err "No SSH_HOST for environment '${SERVER}'. Set it in that GitHub Environment and use 'secrets: inherit' in the caller."
[ -n "${SSH_USER:-}" ]        || err "No SSH_USER for environment '${SERVER}'."
[ -n "${SSH_PRIVATE_KEY:-}" ] || err "No SSH_PRIVATE_KEY for environment '${SERVER}'."
SSH_PORT="${SSH_PORT:-22}"
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] || err "Invalid SSH_PORT '${SSH_PORT}' for '${SERVER}' (must be numeric)."
REMOTE_STACKS_DIR="${REMOTE_STACKS_DIR:-/opt/stacks}"; REMOTE_STACKS_DIR="${REMOTE_STACKS_DIR%/}"

# Per-run private key + known_hosts in a 0700 temp dir; gone on exit.
sshdir="$(mktemp -d)"; chmod 700 "$sshdir"
trap 'rm -rf "$sshdir"' EXIT
key="${sshdir}/id"; printf '%s\n' "$SSH_PRIVATE_KEY" > "$key"; chmod 600 "$key"
kh="${sshdir}/known_hosts"

# Each ephemeral runner must receive independently verified host keys.
[ -n "${SSH_KNOWN_HOSTS:-}" ] || err "No SSH_KNOWN_HOSTS for '${SERVER}'; provision verified host keys before deploying."
printf '%s\n' "$SSH_KNOWN_HOSTS" > "$kh"
ssh_opts=(-i "$key" -p "$SSH_PORT" -o IdentitiesOnly=yes -o BatchMode=yes -o UserKnownHostsFile="$kh" -o StrictHostKeyChecking=yes)

# Transport the trusted checker from the pinned machinery checkout, not fleet data.
policy_path="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/stack_policy_check.py"
policy_b64="$(base64 < "$policy_path" | tr -d '\n')"

dest="${SSH_USER}@${SSH_HOST}"
note "Deploying '${SERVER}' -> ${dest}:${REMOTE_STACKS_DIR}"

# Sync this server's stacks to /opt/stacks. --delete prunes removed stacks; the
# shared, host-provisioned app env (.env or any *.env) is excluded so it is
# neither shipped from the repo nor deleted on the host (the exclude is
# unanchored, so it protects matching files at every depth). A targeted
# single-stack dispatch syncs ONLY that stack's subdir (into its own dest subdir),
# so top-level --delete can never prune a repo-removed sibling's files while its
# teardown is skipped -- a targeted redeploy touches nothing but the named stack.
if [ -n "$ONLY_STACK" ]; then
  rsync_src="${src}/${ONLY_STACK}/"; rsync_dest="${dest}:${REMOTE_STACKS_DIR}/${ONLY_STACK}/"
else
  rsync_src="${src}/"; rsync_dest="${dest}:${REMOTE_STACKS_DIR}/"
fi
rsync -rlptz --delete --exclude='.env' --exclude='*.env' \
  -e "ssh ${ssh_opts[*]}" \
  "$rsync_src" "$rsync_dest"

# Bring up each stack on the host using the shared host-provisioned .env, then
# tear down stacks whose directory was removed. The remote heredoc is quoted (no
# local expansion), so operator-trusted values are passed as positional args:
# $1 remote dir, $2 force-recreate flag, $3 target stack (blank = all).
# SSH joins argv into a remote shell string; quote explicitly, including empty args.
printf -v remote_command '%q ' bash -s -- "$REMOTE_STACKS_DIR" "$FORCE_RECREATE" "$ONLY_STACK" "$policy_b64"
ssh "${ssh_opts[@]}" "$dest" "$remote_command" <<'REMOTE'
set -euo pipefail
REMOTE_DIR="${1:?remote stacks dir}"
FORCE_RECREATE="${2:-false}"
ONLY_STACK="${3:-}"
cd "$REMOTE_DIR"
REMOTE_DIR="$PWD"
umask 077
policy_dir="$(mktemp -d)"
configs=()
cleanup_policy() {
  rm -rf "$policy_dir"
  if [ "${#configs[@]}" -gt 0 ]; then rm -f "${configs[@]}"; fi
}
trap cleanup_policy EXIT
python3 -c 'import base64,sys; open(sys.argv[1], "wb").write(base64.b64decode(sys.argv[2], validate=True))' "$policy_dir/check.py" "${4:?trusted policy required}"


# --env-file only if a shared .env exists (provisioned at setup, not by deploy).
# Absolute path: the up-loop runs from inside each stack dir, so a relative
# ".env" would resolve to the wrong place.
compose_env=()
[ -f .env ] && compose_env=(--env-file "$REMOTE_DIR/.env")

# Optional registry auth: auto-discover DOCKER_REGISTRY_<NAME>_{URL,USER,PASSWORD}
# from the shared .env and log in before pulling private images.
if [ -f .env ]; then
  get_env() { sed -n "s/^${1}=//p" .env; }
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    url="$(get_env "DOCKER_REGISTRY_${name}_URL")"
    pass="$(get_env "DOCKER_REGISTRY_${name}_PASSWORD")"
    if [ -n "$url" ] && [ -n "$pass" ]; then
      echo "==> docker login ${url}"
      printf '%s' "$pass" | docker login "$url" -u "$(get_env "DOCKER_REGISTRY_${name}_USER")" --password-stdin
    fi
  done < <(grep '^DOCKER_REGISTRY_.*_PASSWORD=' .env 2>/dev/null | sed 's/^DOCKER_REGISTRY_//; s/_PASSWORD=.*//')
fi

# Deploy each stack directory that is a valid compose project. Running from
# inside the dir lets Compose auto-discover any canonical filename
# (compose.yaml / compose.yml / docker-compose.yaml / docker-compose.yml), and
# the project name defaults to the (normalized) directory basename -- the same
# name the teardown below compares against.
stack_matched=0
stacks=()
for stack in */; do
  stack="${stack%/}"
  [ -z "$ONLY_STACK" ] || [ "$stack" = "$ONLY_STACK" ] || continue
  [ ! -L "$stack" ] || { echo "::error::stack '${stack}' is a symbolic link"; exit 1; }
  # Documentation/support directories are inert. A present Compose project that
  # fails to resolve must stop the entire deployment, not silently retain old code.
  if [ ! -f "$stack/compose.yaml" ] && [ ! -f "$stack/compose.yml" ] &&
     [ ! -f "$stack/docker-compose.yaml" ] && [ ! -f "$stack/docker-compose.yml" ]; then
    continue
  fi
  if ! ( cd "$stack" && docker compose "${compose_env[@]}" config -q ); then
    echo "::error::stack '${stack}' is not a valid compose project"
    exit 1
  fi
  config="$(mktemp "$REMOTE_DIR/$stack/.miuops-config.XXXXXX")"
  configs+=("$config")
  ( cd "$stack" && docker compose "${compose_env[@]}" config --format json ) > "$config"
  python3 "$policy_dir/check.py" "$config"
  stacks+=("$stack")
  stack_matched=1
done

# Validate every selected stack before starting any; deploy the exact checked model.
for idx in "${!stacks[@]}"; do
  stack="${stacks[$idx]}"
  echo "==> up ${stack}"
  up_args=(-d --pull always --remove-orphans)
  [ "$FORCE_RECREATE" = true ] && up_args+=(--force-recreate)
  ( cd "$stack" && docker compose --project-directory "$PWD" -f "${configs[$idx]}" up "${up_args[@]}" )
done

# A single-stack dispatch that matched NO directory on this server is an operator
# error (typo / wrong server), not a success -- fail loudly rather than exit green
# having done nothing. (Empty ONLY_STACK -> stack_matched is set for every dir.)
if [ -n "$ONLY_STACK" ] && [ "$stack_matched" -eq 0 ]; then
  echo "::error::requested stack '${ONLY_STACK}' not found or not a valid compose project under ${REMOTE_DIR} on this server"
  exit 1
fi

# Tear down stacks whose directory was removed: compare running compose projects
# (rooted under this dir) against the present directories, normalizing each dir
# name the way Compose derives a project name (lowercase; drop chars outside
# [a-z0-9_-]; trim leading separators) so a still-present stack is never flagged.
# Enumeration is best-effort: a missing python3 (or any error) skips pruning --
# the deploy already applied -- rather than failing it. A single-stack manual
# dispatch (ONLY_STACK set) skips teardown entirely: it must never prune the
# sibling stacks it was told not to touch. (The `else` body keeps column-0
# indentation so the <<EOF terminator below stays valid.)
if [ -n "$ONLY_STACK" ]; then
  echo "==> single-stack dispatch (${ONLY_STACK}); skipping removed-stack teardown"
else
teardown_rc=0
if removed="$(docker compose ls --format json 2>/dev/null | python3 -c '
import json, os, re, sys
root = os.getcwd()
def norm(n):
    n = n.lower()
    n = re.sub(r"[^a-z0-9_-]", "", n)
    return re.sub(r"^[_-]+", "", n)
present = {norm(d) for d in os.listdir(root) if os.path.isdir(os.path.join(root, d))}
for p in json.load(sys.stdin):
    cfg = p.get("ConfigFiles", "") or ""
    if cfg.startswith(root + "/") and p["Name"] not in present:
        print(p["Name"])
' 2>/dev/null)"; then
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    echo "==> down (removed) ${name}"
    docker compose -p "$name" down --remove-orphans || { echo "::warning::failed to tear down ${name}"; teardown_rc=1; }
  done <<EOF
$removed
EOF
else
  echo "::warning::Skipped teardown of removed stacks (could not enumerate running projects; is python3 present?)"
fi
[ "$teardown_rc" -eq 0 ] || { echo "::error::one or more removed stacks failed to tear down"; exit 1; }
fi
REMOTE
