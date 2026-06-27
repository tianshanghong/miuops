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

echo "ALL DEPLOY-SERVER SKIP CHECKS PASSED"
