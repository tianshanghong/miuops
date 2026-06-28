#!/usr/bin/env bash
#
# Verification-net foundation for the backup-credential lifecycle program
# (miuops backup-setup / backup-rotate). It locks the ONE mechanism the safe
# secret-write unit (U3) is built on, with a POSITIVE control AND a NEGATIVE
# fixture so a green run is meaningful:
#
#   stdin->sops write is plaintext-safe. A per-server backup credential
#   encrypted FROM STDIN (never a plaintext file) must:
#     * land on disk as ciphertext (contains the `sops` marker / ENC[),
#     * round-trip back to the EXACT secret, and
#     * leave NO plaintext copy of the secret anywhere on disk.
#   This is the construction `miuops backup-{setup,rotate}` MUST use so an
#   interrupted write can never strand a cleartext key in the fleet repo (F3),
#   replacing the legacy "write plaintext file, then sops -e -i" pattern.
#
# The NEGATIVE fixture (a deliberately-leaked plaintext file) proves the
# leak scan can actually FAIL -- a scan that never trips is theater.
#
# Other invariants this program relies on are ALREADY guarded and are NOT
# duplicated here:
#   * per-server IAM policy scope  -> scripts/test/iam-policy-check.sh
#   * SOPS round-trip + tamper-fail -> tests/sops_test.sh
#
# Requires sops + age (CI installs them; see .github/workflows/ci.yml).
# Exit 0 = the mechanism is plaintext-safe and the leak scan has teeth.

set -uo pipefail

fail() { echo "FAIL: $1" >&2; exit 1; }

command -v sops       >/dev/null 2>&1 || fail "sops not installed (brew install sops)"
command -v age-keygen >/dev/null 2>&1 || fail "age-keygen not installed (brew install age)"
command -v jq         >/dev/null 2>&1 || fail "jq not installed"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ── Self-contained SOPS env: throwaway age key + temp .sops.yaml (same posture
#    as tests/sops_test.sh, so the round-trip needs no operator key/YubiKey). ──
export SOPS_AGE_KEY_FILE="$TMP/keys.txt"
age-keygen -o "$SOPS_AGE_KEY_FILE" 2>/dev/null
RECIPIENT="$(age-keygen -y "$SOPS_AGE_KEY_FILE")"
mkdir -p "$TMP/fleet/secrets"
cat > "$TMP/.sops.yaml" <<EOF
creation_rules:
  - path_regex: ^fleet/secrets/.*\.(json|env)\$
    age: ${RECIPIENT}
EOF

SECRET='s3kr3t-rUtdQ9-AKIA-secret-value'
TARGET="fleet/secrets/web1.vars.json"

# ── POSITIVE: encrypt the credential FROM STDIN straight to the target path ──
# (--filename-override applies the .sops.yaml creation_rules to the stdin doc;
#  the plaintext exists only in the pipe, never as a file.)
# SC2094: sops reads /dev/stdin (the pipe), NOT "$TARGET" -- the override is only a
# name used to match creation_rules, so reading the override name while redirecting
# stdout to the same path is intentional and safe (no read-then-truncate hazard).
# shellcheck disable=SC2094
( cd "$TMP" \
    && printf '{"backup_aws_access_key_id":"AKIAEXAMPLE","backup_aws_secret_access_key":"%s"}' "$SECRET" \
       | sops --encrypt --input-type json --output-type json \
              --filename-override "$TARGET" /dev/stdin > "$TARGET" ) \
  || fail "stdin->sops encryption failed"

# on-disk form is ciphertext
grep -q 'ENC\[' "$TMP/$TARGET" || fail "written file is not ciphertext (no ENC[ marker)"
grep -q 'sops'  "$TMP/$TARGET" || fail "written file lacks the sops metadata marker"
# the raw secret must NOT survive in the ciphertext
if grep -qF "$SECRET" "$TMP/$TARGET"; then fail "RAW secret leaked into the ciphertext file"; fi

# round-trip recovers the EXACT secret
GOT="$( cd "$TMP" && sops -d --output-type json "$TARGET" | jq -r '.backup_aws_secret_access_key' )"
[ "$GOT" = "$SECRET" ] || fail "round-trip did not recover the secret (got '${GOT}')"

# no plaintext copy of the secret anywhere on disk (the age key file holds the
# age identity, not the AWS secret, so any hit on $SECRET is a genuine leak)
leak_scan() { grep -rlF "$SECRET" "$1" 2>/dev/null; }
if [ -n "$(leak_scan "$TMP")" ]; then
  fail "a plaintext copy of the secret exists on disk: $(leak_scan "$TMP")"
fi
echo "ok  - stdin->sops write is plaintext-safe and round-trips (F3 mechanism)"

# ── NEGATIVE fixture: a deliberately-leaked plaintext file MUST be caught by
#    the same scan -- proving the leak check has teeth (not theater). ─────────
LEAKED="$TMP/leaked_scratch.json"
printf '{"backup_aws_secret_access_key":"%s"}' "$SECRET" > "$LEAKED"
if [ -z "$(leak_scan "$TMP")" ]; then
  fail "leak scan did NOT detect a planted plaintext secret -- the scan is theater"
fi
rm -f "$LEAKED"
echo "ok  - leak scan detects a planted plaintext secret (negative fixture has teeth)"

echo "BACKUP LIFECYCLE NET: PASS"
exit 0
