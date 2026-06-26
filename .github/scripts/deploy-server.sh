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
#   SSH_KNOWN_HOSTS    pinned known_hosts (optional; when set, host-key checking
#                      is strict — no MITM window. When absent: accept-new TOFU).
#   STACKS_DIR         repo path prefix for stacks (default fleet/stacks).
#   REMOTE_STACKS_DIR  destination on the server (default /opt/stacks).
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

# Fail fast on missing secrets BEFORE any network action, naming the server. A
# typo'd Environment resolves to empty secrets (no cross-server fallback exists),
# so this fails CLOSED — it can never reuse another server's key.
[ -n "${SSH_HOST:-}" ]        || err "No SSH_HOST for environment '${SERVER}'. Set it in that GitHub Environment and use 'secrets: inherit' in the caller."
[ -n "${SSH_USER:-}" ]        || err "No SSH_USER for environment '${SERVER}'."
[ -n "${SSH_PRIVATE_KEY:-}" ] || err "No SSH_PRIVATE_KEY for environment '${SERVER}'."
SSH_PORT="${SSH_PORT:-22}"
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] || err "Invalid SSH_PORT '${SSH_PORT}' for '${SERVER}' (must be numeric)."
STACKS_DIR="${STACKS_DIR:-fleet/stacks}"; STACKS_DIR="${STACKS_DIR%/}"
REMOTE_STACKS_DIR="${REMOTE_STACKS_DIR:-/opt/stacks}"; REMOTE_STACKS_DIR="${REMOTE_STACKS_DIR%/}"

src="${GITHUB_WORKSPACE:-.}/${STACKS_DIR}/${SERVER}"
# A server with no stack directory (e.g. just removed from the fleet) is a clean
# skip, never a blind rsync of a nonexistent source.
[ -d "$src" ] || { note "No stacks for '${SERVER}' (${STACKS_DIR}/${SERVER} absent) — nothing to deploy."; exit 0; }

# Per-run private key + known_hosts in a 0700 temp dir; gone on exit.
sshdir="$(mktemp -d)"; chmod 700 "$sshdir"
trap 'rm -rf "$sshdir"' EXIT
key="${sshdir}/id"; printf '%s\n' "$SSH_PRIVATE_KEY" > "$key"; chmod 600 "$key"
kh="${sshdir}/known_hosts"

# Host-key policy: pin when SSH_KNOWN_HOSTS is provided (no MITM window), else
# accept-new -- trusts the key seen on the first connect of THIS run and rejects
# a key that changes mid-run, but does NOT protect a first-ever connect against a
# MITM. Set the per-server SSH_KNOWN_HOSTS Environment secret to pin (recommended
# for production). Never =no.
ssh_opts=(-i "$key" -p "$SSH_PORT" -o IdentitiesOnly=yes -o BatchMode=yes -o UserKnownHostsFile="$kh")
if [ -n "${SSH_KNOWN_HOSTS:-}" ]; then
  printf '%s\n' "$SSH_KNOWN_HOSTS" > "$kh"
  ssh_opts+=(-o StrictHostKeyChecking=yes)
else
  : > "$kh"
  ssh_opts+=(-o StrictHostKeyChecking=accept-new)
fi

dest="${SSH_USER}@${SSH_HOST}"
note "Deploying '${SERVER}' -> ${dest}:${REMOTE_STACKS_DIR}"

# Sync this server's stacks to /opt/stacks. --delete prunes removed stacks; the
# shared, host-provisioned app env (.env or any *.env) is excluded so it is
# neither shipped from the repo nor deleted on the host (the exclude is
# unanchored, so it protects matching files at every depth).
rsync -rlptz --delete --exclude='.env' --exclude='*.env' \
  -e "ssh ${ssh_opts[*]}" \
  "${src}/" "${dest}:${REMOTE_STACKS_DIR}/"

# Bring up each stack on the host using the shared host-provisioned .env, then
# tear down stacks whose directory was removed. REMOTE_STACKS_DIR is an
# operator-trusted input; it is passed as a positional arg to the remote shell.
ssh "${ssh_opts[@]}" "$dest" bash -s -- "$REMOTE_STACKS_DIR" <<'REMOTE'
set -euo pipefail
REMOTE_DIR="${1:?remote stacks dir}"
cd "$REMOTE_DIR"

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
for stack in */; do
  stack="${stack%/}"
  ( cd "$stack" && docker compose "${compose_env[@]}" config -q ) 2>/dev/null || continue
  echo "==> up ${stack}"
  ( cd "$stack" && docker compose "${compose_env[@]}" up -d --pull always --remove-orphans )
done

# Tear down stacks whose directory was removed: compare running compose projects
# (rooted under this dir) against the present directories, normalizing each dir
# name the way Compose derives a project name (lowercase; drop chars outside
# [a-z0-9_-]; trim leading separators) so a still-present stack is never flagged.
# Enumeration is best-effort: a missing python3 (or any error) skips pruning --
# the deploy already applied -- rather than failing it.
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
REMOTE
