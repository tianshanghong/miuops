#!/usr/bin/env bash
# Lint the reusable deploy workflow's security-critical properties so a future
# edit that weakens per-server isolation, supply-chain pinning, or secret
# hygiene fails CI. Pure structural assertions over the text (no runner needed).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
Y="$ROOT/.github/workflows/deploy.yml"
S="$ROOT/.github/scripts/deploy-server.sh"
fail() { echo "FAIL: $1"; exit 1; }

# Trigger + permissions: reusable only, never fork-exposed, least privilege.
grep -qF 'workflow_call:' "$Y"                              || fail "trigger must be workflow_call"
! grep -q 'pull_request_target' "$Y"                        || fail "must NOT use pull_request_target (fork secret exposure)"
grep -qE '^[[:space:]]*contents: read[[:space:]]*$' "$Y"    || fail "permissions must be contents: read"
! grep -qE '(write-all|contents: write|packages: write|id-token: write)' "$Y" || fail "must not grant any write scope"

# Per-server isolation: the deploy job binds the Environment to the matrix value.
grep -qF 'environment: ${{ matrix.server }}' "$Y"           || fail "deploy job must bind environment to matrix.server (per-server isolation)"
grep -qF 'fromJSON(needs.discover.outputs.servers)' "$Y"    || fail "matrix must come from the discover output"
grep -qF "servers != '[]'" "$Y"                             || fail "deploy must guard against an empty matrix"
grep -qF 'fail-fast: false' "$Y"                            || fail "matrix must set fail-fast: false (one server's failure must not cancel others)"

# Supply chain: every real action use pinned to a 40-hex commit SHA, no tags.
uses_count=$(grep -cE 'uses:[[:space:]]+[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40}' "$Y" || true)
[ "${uses_count:-0}" -ge 2 ]                                || fail "real action uses must be SHA-pinned (found ${uses_count})"
! grep -qE 'uses:[[:space:]]+[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@v[0-9]' "$Y" || fail "an action use is pinned to a mutable tag, not a SHA"

# Secret hygiene: secrets only via env:, never interpolated into a run: string;
# no shell tracing / ssh|rsync verbosity in the deploy script (ignore comments).
! grep -qE 'run:.*\$\{\{[[:space:]]*secrets\.' "$Y"         || fail "a secret is interpolated into a run: string"
code_only="$(grep -vE '^[[:space:]]*#' "$S")"
! printf '%s\n' "$code_only" | grep -qE '(\bset -x\b|ssh[[:space:]]+-v|rsync[[:space:]]+-v)' \
    || fail "deploy-server.sh has tracing/verbosity that could surface a secret"

# Regression guards for confirmed review findings: the deploy must detect ANY
# canonical compose filename (not hard-code docker-compose.yml), normalize the
# project name in teardown so a still-present stack is never flapped, validate
# SSH_PORT numeric, and treat teardown enumeration as best-effort (non-fatal).
grep -qF 'config -q' "$S"               || fail "up-loop must detect any compose filename via 'compose config -q', not a hard-coded name"
grep -qF 'def norm' "$S"                || fail "teardown must normalize dir names to compose project names before comparing"
grep -qE 'SSH_PORT.*=~.*0-9' "$S"       || fail "SSH_PORT must be validated numeric"
grep -qF 'Skipped teardown' "$S"        || fail "teardown enumeration must be best-effort (non-fatal on missing python3)"

echo "ALL DEPLOY WORKFLOW LINT CHECKS PASSED"
