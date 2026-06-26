#!/usr/bin/env bash
# Determine which fleet servers changed in a push and emit them as a compact
# JSON array on stdout (for a GitHub Actions dynamic matrix). Outputs "[]" when
# nothing under a server stack directory changed.
#
# Two independent layers, both unit-testable offline:
#   1. Git range resolution: turn (BEFORE, AFTER) into a list of changed paths,
#      handling first push, unknown/rewritten base, and unrelated history safely.
#   2. Path -> server-name mapping: keep only paths under STACKS_DIR/<server>/...,
#      take <server>, validate it against a strict allowlist, dedupe, sort.
#
# Inputs (environment):
#   BEFORE      git SHA before the push (github.event.before); may be the
#               all-zero SHA on a first push / new branch, or a SHA that no
#               longer exists after a force-push.
#   AFTER       git SHA after the push (github.sha). Required.
#   STACKS_DIR  path prefix that holds per-server stacks. Default: fleet/stacks
#
# Testability: when MIUOPS_CHANGED_PATHS_FILE is set, the changed-path list is
# read from that file (one path per line) instead of being computed from git.
# This lets the path -> server mapping be exercised with fixtures and no git.
#
# Security: a server name comes from an operator-controlled directory name and
# later flows into ssh/rsync arguments and a remote path, so it is validated
# against a strict allowlist here (first gate) and re-validated in the deploy
# job (second gate). The JSON array is built with jq so a crafted name can only
# ever be an inert, escaped JSON string -- never a shell token.

# LC_ALL=C makes the validation globs/regex byte-wise. Under a UTF-8 locale a
# range like [A-Za-z] is collation-ordered and can admit unexpected characters,
# which would weaken the allowlist; force C so the allowlist means exactly what
# it says.
export LC_ALL=C
set -euo pipefail

STACKS_DIR="${STACKS_DIR:-fleet/stacks}"
# Normalize to exactly one trailing slash so prefix matching is unambiguous.
STACKS_DIR="${STACKS_DIR%/}/"

ZERO_SHA="0000000000000000000000000000000000000000"

# A server directory name must start with an alphanumeric and otherwise contain
# only [A-Za-z0-9._-]. Starting with an alphanumeric blocks a leading-dash name
# (which could be read as an ssh/rsync option) and a dotfile/"." / ".." name
# (path traversal). This mirrors the CLI's valid_host_alias allowlist.
NAME_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'

# --- Layer 1: resolve the list of changed paths for this push --------------
changed_paths() {
  if [ -n "${MIUOPS_CHANGED_PATHS_FILE:-}" ]; then
    # Fixtures are newline-delimited; emit NUL-delimited to match the consumer.
    tr '\n' '\0' < "$MIUOPS_CHANGED_PATHS_FILE"
    return
  fi

  local before="${BEFORE:-}"
  local after="${AFTER:?AFTER (github.sha) is required}"

  # First push / new branch (zero SHA), or a base that is not in the object
  # store (force-push, rebase, shallow clone, garbage value): we cannot trust a
  # range, so treat the whole tree as changed -> deploy all present stacks.
  # This fails safe toward "deploy everything", never silently "deploy nothing".
  if [ -z "$before" ] || [ "$before" = "$ZERO_SHA" ] \
     || ! git rev-parse -q --verify "${before}^{commit}" >/dev/null 2>&1; then
    git ls-tree -r -z --name-only "$after"
    return
  fi

  # Base exists but is not an ancestor of AFTER (history was rewritten): diff
  # against the merge-base if one exists; otherwise (unrelated/orphan history)
  # fall back to the whole tree.
  if ! git merge-base --is-ancestor "$before" "$after" >/dev/null 2>&1; then
    local mb
    if mb="$(git merge-base "$before" "$after" 2>/dev/null)" && [ -n "$mb" ]; then
      git diff -z --name-only "$mb" "$after"
    else
      git ls-tree -r -z --name-only "$after"
    fi
    return
  fi

  # Normal fast-forward push.
  git diff -z --name-only "$before" "$after"
}

# --- Layer 2: map changed paths to validated, unique server names ----------
# Read NUL-delimited paths so a path containing spaces or newlines cannot split
# a record. Accumulate unique names without bash-4 associative arrays so the
# script also runs on the macOS system bash (3.2).
servers=""
contains() {
  # contains <needle> -- true if "$needle" is already in the newline list $servers
  case "
${servers}
" in
    *"
$1
"*) return 0 ;;
    *) return 1 ;;
  esac
}

while IFS= read -r -d '' path; do
  [ -n "$path" ] || continue
  case "$path" in
    "$STACKS_DIR"*) : ;;          # under the stacks prefix
    *) continue ;;
  esac
  rest="${path#"$STACKS_DIR"}"    # e.g. "alpha/docker-compose.yml"
  seg="${rest%%/*}"               # first segment -> candidate server name
  # Require something beneath the server directory: a bare "fleet/stacks/alpha"
  # (no file under it) or the prefix itself yields no server.
  [ "$seg" != "$rest" ] || continue
  [ -n "$seg" ] || continue
  case "$seg" in
    .|..) continue ;;             # explicit traversal guard
  esac
  [[ "$seg" =~ $NAME_RE ]] || continue
  contains "$seg" && continue
  servers="${servers:+$servers
}$seg"
done < <(changed_paths)

if [ -z "$servers" ]; then
  printf '[]\n'
  exit 0
fi

# Sort for stable, deduplicated output, then emit as a JSON array. jq --args
# turns each name into an escaped JSON string, so a name with shell
# metacharacters is inert in the output. A portable read loop (not mapfile,
# which needs bash 4) builds the argument list so this also runs on bash 3.2.
sorted=()
while IFS= read -r s; do
  [ -n "$s" ] || continue
  sorted+=("$s")
done < <(printf '%s\n' "$servers" | LC_ALL=C sort -u)
jq -cn '$ARGS.positional' --args "${sorted[@]}"
