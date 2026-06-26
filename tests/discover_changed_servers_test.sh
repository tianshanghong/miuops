#!/usr/bin/env bash
# Unit tests for .github/scripts/discover-changed-servers.sh — the deploy
# workflow's "which servers changed" matrix builder. Two layers:
#   (A) path -> server mapping, via MIUOPS_CHANGED_PATHS_FILE fixtures (no git);
#   (B) git range resolution (first push / normal / inventory-only / unknown
#       base / force-push), via throwaway real git repos.
# Every assertion is paired with the bad input it must reject, so it can FAIL.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/.github/scripts/discover-changed-servers.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

# --- Layer A: path -> server mapping (offline fixtures) --------------------
# expect_map <label> <expected-json> <path...>
expect_map() {
  local label="$1" expected="$2"; shift 2
  local f="$TMP/paths"; printf '%s\n' "$@" > "$f"
  local got; got="$(MIUOPS_CHANGED_PATHS_FILE="$f" bash "$SCRIPT")"
  [ "$got" = "$expected" ] || fail "$label: expected $expected, got $got"
}

expect_map "normal sorted+deduped"          '["api","web"]' \
  'fleet/stacks/web/docker-compose.yml' 'fleet/stacks/api/compose.yml'
expect_map "non-stack paths ignored"        '[]' \
  'fleet/inventory.ini' 'fleet/host_vars/web.yml' 'README.md'
expect_map "prefix itself -> none"          '[]' 'fleet/stacks/'
expect_map "server dir, no file beneath"    '[]' 'fleet/stacks/lonely'
expect_map "substring traps rejected"       '[]' 'fleet/stacksXYZ/web/x' 'notfleet/stacks/web/x'
expect_map "path traversal rejected"        '[]' 'fleet/stacks/../../etc/passwd' 'fleet/stacks/..'
expect_map "injection names rejected"       '[]' 'fleet/stacks/a;rm -rf ~/x' 'fleet/stacks/$(id)/x'
expect_map "leading-dash + dotfile rejected" '[]' 'fleet/stacks/-evil/x' 'fleet/stacks/.hidden/x'
expect_map "valid dot/underscore/digit/upper" '["Web","db.1_node"]' \
  'fleet/stacks/db.1_node/x' 'fleet/stacks/Web/x'
expect_map "deep files + dups -> one"       '["api"]' \
  'fleet/stacks/api/conf/nginx/site.conf' 'fleet/stacks/api/compose.yml' 'fleet/stacks/api/compose.yml'
expect_map "deleted path still counts"      '["web"]' 'fleet/stacks/web/removed.yml'

# empty input -> [] and exit 0 (must not trip set -u)
: > "$TMP/empty"
got="$(MIUOPS_CHANGED_PATHS_FILE="$TMP/empty" bash "$SCRIPT")"
[ "$got" = '[]' ] || fail "empty input: expected [], got $got"

# --- Layer B: git range resolution (real repos) ---------------------------
GR="$TMP/repo"; mkdir -p "$GR"
( cd "$GR" && git init -q && git config user.email t@example.com && git config user.name t \
    && git config commit.gpgsign false )   # throwaway repo: never sign (headless)
gadd() { ( cd "$GR" && mkdir -p "fleet/stacks/$1" && echo x > "fleet/stacks/$1/compose.yml" ); }
gsha() { ( cd "$GR" && git rev-parse HEAD ); }

gadd alpha; gadd beta
( cd "$GR" && git add -A && git commit -qm one ); C1="$(gsha)"

# first push: zero SHA and empty BEFORE both -> all present stacks (ls-tree)
got="$(cd "$GR" && BEFORE="0000000000000000000000000000000000000000" AFTER="$C1" bash "$SCRIPT")"
[ "$got" = '["alpha","beta"]' ] || fail "first-push(zero): got $got"
got="$(cd "$GR" && BEFORE="" AFTER="$C1" bash "$SCRIPT")"
[ "$got" = '["alpha","beta"]' ] || fail "first-push(empty BEFORE): got $got"

# normal diff: only the newly added server
gadd gamma; ( cd "$GR" && git add -A && git commit -qm two ); C2="$(gsha)"
got="$(cd "$GR" && BEFORE="$C1" AFTER="$C2" bash "$SCRIPT")"
[ "$got" = '["gamma"]' ] || fail "normal-diff: expected [gamma], got $got"

# inventory-only change -> [] (pairs with the workflow's if: != '[]' guard)
( cd "$GR" && mkdir -p fleet && echo i > fleet/inventory.ini && git add -A && git commit -qm three ); C3="$(gsha)"
got="$(cd "$GR" && BEFORE="$C2" AFTER="$C3" bash "$SCRIPT")"
[ "$got" = '[]' ] || fail "inventory-only: expected [], got $got"

# unknown/garbage base (force-push to a gone SHA) -> deploy all (fail-safe)
got="$(cd "$GR" && BEFORE="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" AFTER="$C3" bash "$SCRIPT")"
[ "$got" = '["alpha","beta","gamma"]' ] || fail "unknown-base: expected all, got $got"

# non-ancestor base WITH a merge-base -> diff merge-base..after
( cd "$GR" && git checkout -q -b div "$C1" && mkdir -p fleet/stacks/divsrv && echo x > fleet/stacks/divsrv/c.yml && git add -A && git commit -qm div ); CDIV="$(gsha)"
got="$(cd "$GR" && BEFORE="$CDIV" AFTER="$C3" bash "$SCRIPT")"
[ "$got" = '["gamma"]' ] || fail "non-ancestor(merge-base C1..C3): expected [gamma], got $got"

echo "ALL DISCOVER TESTS PASSED"
