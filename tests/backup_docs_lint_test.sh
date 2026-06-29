#!/usr/bin/env bash
#
# The operator-facing backup docs describe the `miuops backup-setup` /
# `miuops backup-rotate` command family -- the single-source-of-truth credential
# lifecycle -- and NOT the superseded manual flow (run the raw setup script, then
# export/paste the AWS creds by hand). This is a drift guard: it fails if a doc
# still teaches the old flow or forgets to mention the new commands.
#
# Pure text lint (no aws/sops); each assertion has a positive and a negative form
# so it can actually fail.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf 'ok   - %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL - %s\n' "$1"; fail=$((fail + 1)); }

# ── POSITIVE: the new command family is the documented entry point ────────────
for d in docs/INSTALLATION.md README.md roles/backup/README.md; do
  if grep -qF 'miuops backup-setup' "$ROOT/$d"; then
    ok "$d documents 'miuops backup-setup'"
  else
    bad "$d does not mention 'miuops backup-setup'"
  fi
done

# (exclude the gitignored *.local.* planning docs -- only a shipped operator doc counts)
if grep -rlF 'miuops backup-rotate' "$ROOT/docs" "$ROOT/roles/backup/README.md" "$ROOT/README.md" 2>/dev/null | grep -qv '\.local\.'; then
  ok "rotation is documented via 'miuops backup-rotate'"
else
  bad "no operator doc mentions 'miuops backup-rotate'"
fi

# ── NEGATIVE (drift sentinels): the superseded instructions are gone ──────────
if grep -qF 'Keep env-only' "$ROOT/roles/backup/README.md"; then
  bad "roles/backup/README.md still calls the creds 'env-only' (superseded by the encrypted vars.json the command writes)"
else
  ok "roles/backup/README.md dropped the stale 'env-only' creds note"
fi

# INSTALLATION's backup step must be the command, not a bare raw-script invocation.
if grep -qE '^\./scripts/setup-s3-backup\.sh[[:space:]]*$' "$ROOT/docs/INSTALLATION.md"; then
  bad "docs/INSTALLATION.md still shows the bare './scripts/setup-s3-backup.sh' as the setup step"
else
  ok "docs/INSTALLATION.md setup step is the command, not the raw script"
fi

# The role README's creds prose must not teach env-export as THE mechanism (it's a
# fallback) -- this sentinel guards the prose block, not just the var table.
if grep -qiF 'export them as environment variables' "$ROOT/roles/backup/README.md"; then
  bad "roles/backup/README.md still teaches env-export as the primary creds path (it's a fallback)"
else
  ok "roles/backup/README.md does not teach env-export as the primary creds path"
fi

echo "== ${pass} passed, ${fail} failed =="
[ "$fail" -eq 0 ]
