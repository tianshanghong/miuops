#!/usr/bin/env bash
# A symlinked invocation (e.g. /usr/local/bin/miuops -> the checkout) must still
# resolve SCRIPT_DIR to the REAL tool dir, so assets (playbook/roles/requirements)
# are found relative to the real script, not the symlink. Regression for the
# "requirements file '/usr/local/bin/requirements.yml' does not exist" bug.
# `miuops version` reports the resolved tool dir; we assert it via a PATH symlink.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $1"; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
ln -s "$ROOT/miuops" "$tmp/bin/miuops"

# Invoke via the PATH symlink, from an unrelated cwd, with NO MIUOPS_TEST_SCRIPT_DIR
# override -- so the real resolution (line 4) runs.
got="$(cd "$tmp" && PATH="$tmp/bin:$PATH" MIUOPS_TEST_SCRIPT_DIR='' miuops version 2>/dev/null \
        | sed -n 's/^tool dir:[[:space:]]*//p')"
[ "$got" = "$ROOT" ] \
    || fail "symlinked 'miuops version' reported tool dir '$got', expected '$ROOT'"

# 2) argv[0] spoofed to a bare name via `exec -a` -- bash still sets
#    BASH_SOURCE[0] to the resolved script path, so this confirms argv[0] spoofing
#    does not break resolution. (The command -v fallback at miuops:~16 is reachable
#    only by a *sourced* bare name; the --source-only path uses the override there,
#    so that branch is defensive and verified by reasoning, not exercised here.)
got2="$(cd / && PATH="$tmp/bin:$PATH" MIUOPS_TEST_SCRIPT_DIR='' \
        bash -c 'exec -a miuops miuops version' 2>/dev/null \
        | sed -n 's/^tool dir:[[:space:]]*//p')"
[ "$got2" = "$ROOT" ] \
    || fail "bare-name (command -v) 'miuops version' reported '$got2', expected '$ROOT'"

echo "ALL SCRIPT_DIR RESOLUTION CHECKS PASSED"
