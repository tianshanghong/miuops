#!/usr/bin/env bash
#
# sync_backup_env — keep a WAL-G server's stack .env (fleet/secrets/<host>.env)
# AWS backup credentials in sync with a freshly minted/rotated key, so that
# rotating the key never strands WAL-G on a deleted key. Guarantees:
#   * updates AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY in place and preserves
#     EVERY other line (WALG_S3_PREFIX, DATABASE_URL, …);
#   * stdin -> sops (dotenv): the new secret never lands on disk in plaintext;
#   * no-op when the .env is absent OR carries no AWS_ACCESS_KEY_ID (i.e. not a
#     backup-bearing stack env) -- it never INJECTS AWS creds into an unrelated env.
#
# Real sops dotenv round-trip with a throwaway age key.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $1" >&2; exit 1; }
command -v sops       >/dev/null 2>&1 || fail "sops not installed"
command -v age-keygen >/dev/null 2>&1 || fail "age-keygen not installed"

# shellcheck source=/dev/null
MIUOPS_S3_SETUP_LIB=1 . "$ROOT/scripts/setup-s3-backup.sh"
declare -F sync_backup_env >/dev/null 2>&1 || fail "sync_backup_env not defined in library mode"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export SOPS_AGE_KEY_FILE="$TMP/keys.txt"
age-keygen -o "$SOPS_AGE_KEY_FILE" 2>/dev/null
RECIPIENT="$(age-keygen -y "$SOPS_AGE_KEY_FILE")"
mkdir -p "$TMP/fleet/secrets"
cat > "$TMP/.sops.yaml" <<EOF
creation_rules:
  - path_regex: ^fleet/secrets/.*\.env\$
    age: ${RECIPIENT}
EOF

REL="fleet/secrets/web1.env"
TGT="$TMP/$REL"
NEW_ID="AKIAROTATEDID0000001"
NEW_SECRET="rotated-Secret/9mX+Lp"
seal_env() {  # stdin (plaintext dotenv) -> encrypted $TGT
  ( cd "$TMP" && sops --encrypt --input-type dotenv --output-type dotenv --filename-override "$REL" /dev/stdin ) > "$TGT"
}
leaks() { grep -rlF "$1" "$TMP" 2>/dev/null | grep -v keys.txt; }

# ── 1. .env with AWS creds + unrelated keys -> updates creds, preserves the rest ──
printf 'WALG_S3_PREFIX=s3://b/web1/db\nAWS_ACCESS_KEY_ID=OLDID\nAWS_SECRET_ACCESS_KEY=OLDSECRET\nDATABASE_URL=postgres://x/y\n' | seal_env
sync_backup_env "$TMP" "$REL" "$NEW_ID" "$NEW_SECRET" >/dev/null || fail "sync returned non-zero on a backup .env"
grep -q 'ENC\[' "$TGT" || fail "result is not ciphertext"
if grep -qF "$NEW_SECRET" "$TGT"; then fail "new secret leaked in ciphertext"; fi
dec="$( cd "$TMP" && sops -d --output-type dotenv "$REL" )"
grep -qx "AWS_ACCESS_KEY_ID=${NEW_ID}" <<<"$dec"        || fail "AWS_ACCESS_KEY_ID not updated"
grep -qx "AWS_SECRET_ACCESS_KEY=${NEW_SECRET}" <<<"$dec" || fail "AWS_SECRET_ACCESS_KEY not updated"
grep -qx 'WALG_S3_PREFIX=s3://b/web1/db' <<<"$dec"      || fail "CLOBBERED WALG_S3_PREFIX"
grep -qx 'DATABASE_URL=postgres://x/y' <<<"$dec"        || fail "CLOBBERED DATABASE_URL"
[ -z "$(leaks "$NEW_SECRET")" ] || fail "plaintext copy of the new secret on disk: $(leaks "$NEW_SECRET")"
echo "ok  - backup .env: updates AWS creds, preserves other keys, no plaintext"

# ── 2. .env WITHOUT AWS creds -> left untouched (never injects creds) ─────────
printf 'WALG_S3_PREFIX=s3://b/web1/db\nDATABASE_URL=postgres://x/y\n' | seal_env
before="$( cd "$TMP" && sops -d --output-type dotenv "$REL" )"
sync_backup_env "$TMP" "$REL" "$NEW_ID" "$NEW_SECRET" >/dev/null || fail "sync returned non-zero on a non-backup .env"
after="$( cd "$TMP" && sops -d --output-type dotenv "$REL" )"
[ "$before" = "$after" ] || fail "a non-backup .env was modified (creds injected)"
if grep -qF "$NEW_ID" <<<"$after"; then fail "injected AWS_ACCESS_KEY_ID into a .env that had none"; fi
echo "ok  - non-backup .env: left untouched (no creds injected)"

# ── 3. no .env at all -> no-op, success ──────────────────────────────────────
rm -f "$TGT"
sync_backup_env "$TMP" "$REL" "$NEW_ID" "$NEW_SECRET" >/dev/null || fail "sync should be a no-op (0) when the .env is absent"
[ -f "$TGT" ] || echo "ok  - absent .env: no-op, no file created"

echo "BACKUP ENV SYNC: PASS"
exit 0
