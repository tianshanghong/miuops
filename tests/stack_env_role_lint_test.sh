#!/usr/bin/env bash
# Tripwire for the stack-env role's security-critical properties, so a future edit that
# weakens the secret handling fails CI. Pure structural assertions over the YAML text --
# the role is a no-op in the CI converge (no secret present), so nothing else exercises it.
# The behavioural guarantees (byte-identical, idempotent, fail-closed) are proven by the
# real-aarch64 e2e at PR time; this catches the realistic regressions.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$ROOT/roles/stack-env/tasks/main.yml"
fail() { echo "FAIL: $1"; exit 1; }

# Decryption stays on the CONTROLLER via community.sops (a thin sops wrapper -- no new
# crypto, age key never leaves the controller); the plaintext is written by `copy`, which
# is atomic (temp+rename) and idempotent (writes only on change).
grep -qF "community.sops.sops" "$T" \
    || fail "must decrypt via community.sops.sops (controller-side; wraps the sops binary)"
grep -qF "ansible.builtin.copy" "$T" \
    || fail "must write the .env via ansible.builtin.copy (atomic + idempotent), not a shell write"

# The .env is a secret: 0600 + no_log so the plaintext never lands in logs.
grep -qF "mode: '0600'" "$T" || fail ".env must be written 0600"
grep -qF "no_log: true"  "$T" || fail "the secret-bearing task must set no_log: true"
grep -qF "become: true"  "$T" || fail "tasks must escalate (become: true) to write root-owned /opt/stacks/.env"

# Provision ONLY when the host actually has a secret (a host with none is left untouched),
# and only when the secrets dir was handed in (fail-closed against an unset path).
grep -qF "is exists"          "$T" || fail "must provision only when fleet/secrets/<host>.env exists"
grep -qF "miuops_secrets_dir | length > 0" "$T" || fail "must guard on miuops_secrets_dir being non-empty (a default + length check, fail-closed against an unset/empty path)"

echo "ALL STACK-ENV ROLE LINT CHECKS PASSED"
