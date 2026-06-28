#!/usr/bin/env bash
#
# write_backup_secret — write a server's new AWS backup creds into
# fleet/secrets/<server>.vars.json, SOPS-encrypted, with two guarantees:
#   * no plaintext on disk: the creds go STDIN -> sops (and a merge decrypts only
#     to a pipe), so an interrupted write can never strand a cleartext key;
#   * merge, never clobber: if the file already holds OTHER vars (e.g. a deployed
#     token), they are preserved; only the two backup-cred keys are (over)written.
#
# Real sops round-trip with a throwaway age key (no operator key / YubiKey for the
# fresh path; the merge path decrypts with the throwaway key here). Each assertion
# checks a concrete property; the secret is a distinctive literal so a leak scan is
# meaningful.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $1" >&2; exit 1; }
command -v sops       >/dev/null 2>&1 || fail "sops not installed"
command -v age-keygen >/dev/null 2>&1 || fail "age-keygen not installed"
command -v jq         >/dev/null 2>&1 || fail "jq not installed"

# Source the setup script as a library: it must define write_backup_secret and
# return WITHOUT running the interactive provisioning flow.
# shellcheck source=/dev/null
MIUOPS_S3_SETUP_LIB=1 . "$ROOT/scripts/setup-s3-backup.sh"
declare -F write_backup_secret >/dev/null 2>&1 || fail "write_backup_secret not defined in library mode"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export SOPS_AGE_KEY_FILE="$TMP/keys.txt"
age-keygen -o "$SOPS_AGE_KEY_FILE" 2>/dev/null
RECIPIENT="$(age-keygen -y "$SOPS_AGE_KEY_FILE")"
mkdir -p "$TMP/fleet/secrets"
cat > "$TMP/.sops.yaml" <<EOF
creation_rules:
  - path_regex: ^fleet/secrets/.*\.(json|env)\$
    age: ${RECIPIENT}
EOF

REL="fleet/secrets/web1.vars.json"
TGT="$TMP/$REL"
SECRET='AKIAsecret-Value-rb7/qZ+first'
leaks() { grep -rlF "$1" "$TMP" 2>/dev/null; }

# ── 1. FRESH write (no existing file): ciphertext, round-trips, no plaintext ──
write_backup_secret "$TMP" "$REL" "AKIAFIRSTID000000001" "$SECRET" >/dev/null \
  || fail "fresh write returned non-zero"
grep -q 'ENC\[' "$TGT" || fail "fresh: file is not ciphertext"
if grep -qF "$SECRET" "$TGT"; then fail "fresh: raw secret leaked into ciphertext file"; fi
got="$( cd "$TMP" && sops -d --output-type json "$REL" | jq -r '.backup_aws_secret_access_key' )"
[ "$got" = "$SECRET" ] || fail "fresh: round-trip mismatch (got '${got}')"
[ -z "$(leaks "$SECRET")" ] || fail "fresh: a plaintext copy of the secret exists on disk: $(leaks "$SECRET")"
echo "ok  - fresh write: ciphertext + exact round-trip + no plaintext on disk"

# ── 2. MERGE: an UNRELATED key already in the file must survive; creds update ──
# Seed the file with an unrelated deployed var + stale backup creds, encrypted.
printf '{"grafana_cloud_token":"glc_KEEP_ME","backup_aws_access_key_id":"OLDID","backup_aws_secret_access_key":"OLDSECRET"}' \
  | ( cd "$TMP" && sops --encrypt --input-type json --output-type json --filename-override "$REL" /dev/stdin ) > "$TMP/seed" \
  && mv "$TMP/seed" "$TGT"
NEW='AKIAsecret-Value-9mX/Lp+second'
write_backup_secret "$TMP" "$REL" "AKIASECONDID00000002" "$NEW" >/dev/null \
  || fail "merge write returned non-zero"
dec="$( cd "$TMP" && sops -d --output-type json "$REL" )"
[ "$(printf '%s' "$dec" | jq -r '.grafana_cloud_token')" = "glc_KEEP_ME" ] \
  || fail "merge CLOBBERED the unrelated key grafana_cloud_token"
[ "$(printf '%s' "$dec" | jq -r '.backup_aws_access_key_id')" = "AKIASECONDID00000002" ] \
  || fail "merge did not update backup_aws_access_key_id"
[ "$(printf '%s' "$dec" | jq -r '.backup_aws_secret_access_key')" = "$NEW" ] \
  || fail "merge did not update backup_aws_secret_access_key"
grep -q 'ENC\[' "$TGT" || fail "merge: file is not ciphertext"
[ -z "$(leaks "$NEW")" ] || fail "merge: a plaintext copy of the new secret exists on disk"
echo "ok  - merge write: preserves unrelated keys + updates creds + no plaintext"

echo "BACKUP SECRET WRITE: PASS"
exit 0
