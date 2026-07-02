#!/usr/bin/env bash
# A server with no stack directory must be a clean skip (exit 0), even when its
# GitHub Environment has no SSH secrets -- e.g. a stack removed from the fleet, or
# the template's example server that has no Environment. The SSH-secret check must
# STILL fire when the server DOES have stacks. Regression: deploy-server.sh checked
# the SSH secrets BEFORE the no-stacks skip, so a removed / Environment-less server
# reddened the Deploy run with "No SSH_HOST".
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DS="$ROOT/.github/scripts/deploy-server.sh"
fail() { echo "FAIL: $1"; exit 1; }

ws="$(mktemp -d)"; trap 'rm -rf "$ws"' EXIT
mkdir -p "$ws/fleet/stacks/has-stacks/app"   # a server WITH a stack dir
# (intentionally NO dir for server "no-stacks")

# Case 1: no stack dir + no SSH secrets -> clean skip (exit 0), notes "No stacks".
rc=0
out="$(SERVER=no-stacks GITHUB_WORKSPACE="$ws" SSH_HOST='' SSH_USER='' SSH_PRIVATE_KEY='' \
       bash "$DS" 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "no-stacks + no-SSH must exit 0 (clean skip), got rc=$rc: $out"
printf '%s' "$out" | grep -q 'No stacks' || fail "no-stacks skip must note 'No stacks', got: $out"

# Case 2 (positive control): stacks present + no SSH secrets -> MUST still err.
rc=0
out="$(SERVER=has-stacks GITHUB_WORKSPACE="$ws" SSH_HOST='' SSH_USER='' SSH_PRIVATE_KEY='' \
       bash "$DS" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "stacks present + no-SSH must FAIL the SSH check, but exited 0: $out"
printf '%s' "$out" | grep -q 'No SSH_HOST' || fail "stacks + no-SSH must err 'No SSH_HOST', got: $out"

# Case 3: an invalid ONLY_STACK (dispatch input) must be rejected up front, BEFORE
# any SSH/network action -- the operator-controlled target is held to the same
# name allowlist as SERVER so it can never reach the remote as a shell token.
for bad in 'e;vil' '-x' '../etc' '.' 'a b'; do
  rc=0
  out="$(SERVER=has-stacks ONLY_STACK="$bad" GITHUB_WORKSPACE="$ws" SSH_HOST='' SSH_USER='' SSH_PRIVATE_KEY='' \
         bash "$DS" 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail "invalid ONLY_STACK '$bad' must FAIL, got rc=0: $out"
  printf '%s' "$out" | grep -q 'invalid stack name' || fail "invalid ONLY_STACK '$bad' must err 'invalid stack name', got: $out"
done

# Case 4: FORCE_RECREATE must be exactly true|false (never an arbitrary string
# that could imply an unintended flag). A junk value fails closed.
rc=0
out="$(SERVER=has-stacks FORCE_RECREATE='yes' GITHUB_WORKSPACE="$ws" SSH_HOST='' SSH_USER='' SSH_PRIVATE_KEY='' \
       bash "$DS" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "invalid FORCE_RECREATE must FAIL, got rc=0: $out"
printf '%s' "$out" | grep -q 'FORCE_RECREATE must be' || fail "invalid FORCE_RECREATE must err, got: $out"

# Case 5 (positive control): a VALID ONLY_STACK + force_recreate passes validation
# and proceeds to the SSH check (proving the guards don't reject good input).
rc=0
out="$(SERVER=has-stacks ONLY_STACK=app FORCE_RECREATE=true GITHUB_WORKSPACE="$ws" SSH_HOST='' SSH_USER='' SSH_PRIVATE_KEY='' \
       bash "$DS" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "valid targeting + no-SSH must still reach the SSH check, got rc=0: $out"
printf '%s' "$out" | grep -q 'No SSH_HOST' || fail "valid targeting must pass validation and hit SSH check, got: $out"

# Case 6: a targeted stack that does NOT exist in the repo fails fast (before SSH),
# not a silent sync-nothing. (has-stacks has 'app'; 'nope' is absent.)
rc=0
out="$(SERVER=has-stacks ONLY_STACK=nope GITHUB_WORKSPACE="$ws" SSH_HOST='' SSH_USER='' SSH_PRIVATE_KEY='' \
       bash "$DS" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "missing target stack must FAIL before SSH, got rc=0: $out"
printf '%s' "$out" | grep -q 'does not exist' || fail "missing target stack must err 'does not exist', got: $out"

# Case 7: targeting a stack on a server with NO stacks dir is an error, not the
# removed-server exit-0 skip (that skip still applies only when ONLY_STACK empty).
rc=0
out="$(SERVER=no-stacks ONLY_STACK=app GITHUB_WORKSPACE="$ws" SSH_HOST='' SSH_USER='' SSH_PRIVATE_KEY='' \
       bash "$DS" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "targeting a stack on a serverless server must FAIL, got rc=0: $out"
printf '%s' "$out" | grep -q 'Cannot target stack' || fail "serverless targeted dispatch must err 'Cannot target stack', got: $out"

echo "ALL DEPLOY-SERVER SKIP CHECKS PASSED"
