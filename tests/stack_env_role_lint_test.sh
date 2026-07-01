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

# Decryption must NOT happen in-play. A community.sops lookup runs in a TTY-less subprocess
# that cannot obtain an age YubiKey's PIN, so it fails fail-closed on a YubiKey-only fleet.
# The miuops CLI decrypts on the control node (with a TTY) and passes the plaintext path;
# this task only copies it. Fail if a future edit reintroduces in-play decryption.
if grep -qF "community.sops" "$T"; then
    fail "the role must NOT decrypt in-play (community.sops) -- a TTY-less lookup cannot get a YubiKey PIN; the CLI decrypts with a TTY and passes stack_env_content_src"
fi

# The .env is written from the CLI-decrypted plaintext (a controller-local path in
# stack_env_content_src) via copy: atomic (temp+rename) + idempotent (writes only on change).
grep -qF "ansible.builtin.copy" "$T" \
    || fail "must write the .env via ansible.builtin.copy (atomic + idempotent), not a shell write"
grep -qE 'src:[[:space:]]+"\{\{[[:space:]]*stack_env_content_src' "$T" \
    || fail "the provision task must copy FROM stack_env_content_src (src:), i.e. the CLI-decrypted path, not an in-play lookup"

# The .env is a secret: 0600 + no_log so the plaintext never lands in logs.
grep -qF "mode: '0600'" "$T" || fail ".env must be written 0600"
grep -qF "no_log: true"  "$T" || fail "the secret-bearing task must set no_log: true"
grep -qF "become: true"  "$T" || fail "tasks must escalate (become: true) to write root-owned /opt/stacks/.env"

# Provision ONLY when the CLI handed in a decrypted path. A host with no secret, or a
# whole-fleet apply, passes nothing -> the guard skips and the empty placeholder is kept
# (never an empty/rogue .env write). Fail-closed against an unset/empty path.
grep -qF "stack_env_content_src | length > 0" "$T" \
    || fail "must guard on stack_env_content_src being non-empty (fail-closed against an unset/empty path)"

echo "ALL STACK-ENV ROLE LINT CHECKS PASSED"
