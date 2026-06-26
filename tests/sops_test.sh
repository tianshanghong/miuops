#!/usr/bin/env bash
# Oracle for the SOPS+age secret integration. Self-contained: it generates a
# throwaway age key and a temp .sops.yaml so the round-trip needs no operator
# key and never touches the real fleet repo. Proves, with each assertion able
# to FAIL independently:
#   1. ROUND-TRIP (tunnel cred JSON): encrypt -> ciphertext is not plaintext ->
#      decrypt -> byte-identical to the original.
#   2. ROUND-TRIP (app .env): values are encrypted on disk but decrypt back.
#   3. TAMPER fails closed: flip one ciphertext byte -> `sops -d` exits non-zero,
#      stderr mentions MAC, and NO plaintext is emitted on stdout.
#   4. The CLI's sops helpers exist and behave: require_sops dies when sops is
#      absent; the env-provisioning command targets mode 0600; the cloudflared
#      role consumes a local decrypted source with a legacy fallback.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

command -v sops >/dev/null 2>&1 || fail "sops not installed (brew install sops age)"
command -v age-keygen >/dev/null 2>&1 || fail "age-keygen not installed (brew install age)"

# ── Self-contained SOPS env: throwaway age key + temp .sops.yaml ────────────
# The fleet repo ROOT is $TMP; secrets live under $TMP/fleet/secrets (the
# authoritative convention: invoke sops with cwd = repo root, repo-relative
# paths 'fleet/secrets/<file>', path_regex '^fleet/secrets/.*\.(json|env)$').
export SOPS_AGE_KEY_FILE="$TMP/keys.txt"
age-keygen -o "$SOPS_AGE_KEY_FILE" 2>/dev/null
RECIPIENT="$(age-keygen -y "$SOPS_AGE_KEY_FILE")"
[ -n "$RECIPIENT" ] || fail "could not derive age recipient"

mkdir -p "$TMP/fleet/secrets"
cat > "$TMP/.sops.yaml" <<EOF
creation_rules:
  - path_regex: ^fleet/secrets/.*\.(json|env)\$
    age: ${RECIPIENT}
EOF

# ── 1. ROUND-TRIP: tunnel credential JSON ───────────────────────────────────
TID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
cat > "$TMP/orig-cred.json" <<EOF
{"AccountTag":"acct123","TunnelID":"${TID}","TunnelName":"miuops-test","TunnelSecret":"c2VjcmV0LXZhbHVlLWhlcmU="}
EOF
cp "$TMP/orig-cred.json" "$TMP/fleet/secrets/${TID}.json"
( cd "$TMP" && sops --encrypt --input-type json --output-type json --in-place "fleet/secrets/${TID}.json" ) \
    || fail "sops encrypt failed for the tunnel cred JSON"
# Ciphertext must NOT be plaintext: the raw secret value is gone, sops metadata present.
grep -q 'c2VjcmV0LXZhbHVlLWhlcmU=' "$TMP/fleet/secrets/${TID}.json" \
    && fail "tunnel secret left in plaintext after encrypt (encrypt no-op)"
grep -q '"sops"' "$TMP/fleet/secrets/${TID}.json" \
    || fail "no sops metadata in the encrypted tunnel cred (not encrypted)"
# Decrypt and compare to the original. SOPS reformats JSON (pretty-prints) on
# decrypt, so compare the CANONICAL form (jq -S -c) byte-for-byte: this still
# catches a mangled/corrupted object or a changed value while tolerating
# whitespace reformatting — and cloudflared only consumes the JSON content.
( cd "$TMP" && sops --decrypt "fleet/secrets/${TID}.json" ) > "$TMP/dec-cred.json" \
    || fail "sops decrypt failed for the tunnel cred JSON"
cmp -s <(jq -S -c . "$TMP/orig-cred.json") <(jq -S -c . "$TMP/dec-cred.json") \
    || fail "decrypted tunnel cred does not match the original (canonical JSON)"
# The decrypted JSON is still valid and carries the expected fields/values.
jq -e --arg s 'c2VjcmV0LXZhbHVlLWhlcmU=' '.TunnelID and .TunnelSecret == $s' "$TMP/dec-cred.json" >/dev/null \
    || fail "decrypted tunnel cred lost a field/value"
echo "ok: tunnel cred JSON round-trip (encrypt hides secret, decrypt restores content)"

# ── 2. ROUND-TRIP: app .env (value-only encryption) ─────────────────────────
SRV="server-a"
printf 'FOO=bar123\n# a comment with = signs and spaces\nDB_URL=postgres://u:p@h/db\n' > "$TMP/orig.env"
cp "$TMP/orig.env" "$TMP/fleet/secrets/${SRV}.env"
( cd "$TMP" && sops --encrypt --input-type dotenv --output-type dotenv --in-place "fleet/secrets/${SRV}.env" ) \
    || fail "sops encrypt failed for the app .env"
# Value must be encrypted on disk...
grep -q '^FOO=bar123$' "$TMP/fleet/secrets/${SRV}.env" \
    && fail ".env value left in plaintext after encrypt"
# ...but decrypt back to the exact value.
( cd "$TMP" && sops --decrypt --input-type dotenv --output-type dotenv "fleet/secrets/${SRV}.env" ) > "$TMP/dec.env" \
    || fail "sops decrypt failed for the app .env"
grep -q '^FOO=bar123$' "$TMP/dec.env" \
    || fail "decrypted .env lost the FOO=bar123 value"
grep -q '^DB_URL=postgres://u:p@h/db$' "$TMP/dec.env" \
    || fail "decrypted .env lost the DB_URL value"
echo "ok: app .env round-trip (value encrypted on disk, decrypts back)"

# ── 3. TAMPER: a flipped ciphertext byte must fail closed ───────────────────
# Positive control first: the un-tampered file decrypts cleanly (exit 0).
( cd "$TMP" && sops --decrypt "fleet/secrets/${TID}.json" ) >/dev/null 2>&1 \
    || fail "positive control: un-tampered cred should decrypt (exit 0)"
# Flip one base64 char inside the encrypted "mac" value (the integrity tag over
# the whole tree). SOPS authenticates the tree against this MAC, so any change
# makes decryption fail closed with a MAC error (exit code 51, MacMismatch).
TAMPERED="$TMP/tampered.json"
python3 - "$TMP/fleet/secrets/${TID}.json" "$TAMPERED" <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
m = re.search(r'("mac": "ENC\[AES256_GCM,data:)([A-Za-z0-9+/])', s)
if not m:
    sys.exit("could not locate the mac data field to tamper")
ch = m.group(2)
new = 'B' if ch != 'B' else 'C'
open(dst, 'w').write(s[:m.start(2)] + new + s[m.end(2):])
PY
cmp -s "$TMP/fleet/secrets/${TID}.json" "$TAMPERED" \
    && fail "tamper mutation did not change the ciphertext (test would be vacuous)"
mkdir -p "$TMP/tamper/fleet/secrets"
cp "$TMP/.sops.yaml" "$TMP/tamper/.sops.yaml"
cp "$TAMPERED" "$TMP/tamper/fleet/secrets/${TID}.json"
set +e
out="$( cd "$TMP/tamper" && sops --decrypt "fleet/secrets/${TID}.json" 2>"$TMP/tamper.err" )"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "tampered ciphertext decrypted with exit 0 (did NOT fail closed)"
# No plaintext leaked on stdout (the original secret must not appear).
printf '%s' "$out" | grep -q 'c2VjcmV0LXZhbHVlLWhlcmU=' \
    && fail "tampered decrypt emitted plaintext on stdout (must emit none)"
# SOPS reports a MAC failure on a tampered tree.
grep -qi 'MAC' "$TMP/tamper.err" \
    || fail "tampered decrypt did not report a MAC error (stderr: $(cat "$TMP/tamper.err"))"
echo "ok: tamper fails closed (non-zero exit ${rc}, MAC error, no plaintext)"

# ── 4. CLI helper contract ──────────────────────────────────────────────────
# Source the CLI offline (no dispatch) and exercise the sops helpers directly.
export MIUOPS_TEST_SCRIPT_DIR="$TMP/tool"
export MIUOPS_FLEET_DIR="$TMP/fleet"
# shellcheck disable=SC1090
source "$ROOT/miuops" --source-only

# require_sops must exist and must DIE when sops is not on PATH. The helper uses
# only the `command` builtin + die(), both already sourced, so we can run it in a
# subshell with PATH pointed at an empty dir (sops absent) without losing bash.
type require_sops >/dev/null 2>&1 || fail "require_sops helper is missing"
mkdir -p "$TMP/emptybin"
# die() calls exit, which terminates the subshell with non-zero — so the `|| true`
# must guard the whole assignment (an inner `|| true` would never run).
out="$( PATH="$TMP/emptybin" require_sops 2>&1 )" || true
echo "$out" | grep -qi 'sops not found' \
    || fail "require_sops must die with a clear 'sops not found' message when sops is absent (got: $out)"
echo "ok: require_sops fails closed when sops is missing"

# sops_decrypt_to_tmp must round-trip a fleet secret to a private temp file.
type sops_decrypt_to_tmp >/dev/null 2>&1 || fail "sops_decrypt_to_tmp helper is missing"
plain="$(sops_decrypt_to_tmp "${MIUOPS_FLEET_DIR}/secrets/${TID}.json")" \
    || fail "sops_decrypt_to_tmp failed on a valid encrypted cred"
[ -f "$plain" ] || fail "sops_decrypt_to_tmp did not produce a temp file"
cmp -s <(jq -S -c . "$TMP/orig-cred.json") <(jq -S -c . "$plain") \
    || fail "sops_decrypt_to_tmp output does not match the original cred (canonical JSON)"
# The temp file must be 0600 (no plaintext readable by group/other).
perm="$(stat -c '%a' "$plain" 2>/dev/null || stat -f '%Lp' "$plain")"
[ "$perm" = "600" ] || fail "decrypt temp file not 0600 (got $perm)"
rm -f "$plain"
echo "ok: sops_decrypt_to_tmp round-trips to a 0600 temp file"

# The .env provisioning command targets /opt/stacks/.env at mode 0600, root-owned.
type sops_env_install_cmd >/dev/null 2>&1 || fail "sops_env_install_cmd helper is missing"
cmd="$(sops_env_install_cmd)"
echo "$cmd" | grep -q '/opt/stacks/.env'      || fail "env provision must target /opt/stacks/.env (got: $cmd)"
echo "$cmd" | grep -qE '0600|install -m 0600' || fail "env provision must enforce mode 0600 (got: $cmd)"
echo "ok: env provisioning targets /opt/stacks/.env at mode 0600"

# CLI source must wire the decrypted cred into the playbook via cloudflared_credentials_src.
grep -q 'cloudflared_credentials_src=' "$ROOT/miuops" \
    || fail "CLI must pass -e cloudflared_credentials_src=<decrypted temp> to the playbook"

# ── 5. cloudflared role consumes a local decrypted source, legacy fallback ───
ROLE="$ROOT/roles/cloudflared/tasks/main.yml"
DEFAULTS="$ROOT/roles/cloudflared/defaults/main.yml"
grep -q 'cloudflared_credentials_src' "$DEFAULTS" \
    || fail "defaults must declare cloudflared_credentials_src"
grep -q 'cloudflared_credentials_src' "$ROLE" \
    || fail "role must reference cloudflared_credentials_src"
# Legacy fallback to files/<tunnel_id>.json must remain for backward-compat.
grep -q "files/' + tunnel_id" "$ROLE" \
    || fail "role must fall back to the legacy files/<tunnel_id>.json when src is empty"
# The server-copy step must still land 0600 with no_log.
grep -q "mode: '0600'" "$ROLE" || fail "role must copy the cred to the server at 0600"
grep -q 'no_log: true'    "$ROLE" || fail "role cred copy must keep no_log: true"
# YAML parses.
python3 -c "import yaml,sys; yaml.safe_load(open('$ROLE')); yaml.safe_load(open('$DEFAULTS'))" \
    || fail "cloudflared role/defaults YAML does not parse"
echo "ok: cloudflared role consumes the local decrypted source with a legacy fallback"

# ── 6. set -u safety: the sops helpers must reach their OWN preconditions, never die
# at a `local` line with "unbound variable". bash expands ALL `local` initializers
# before assigning, so a same-statement forward reference reads the outer/unset value
# -> set -u abort (the helper would be dead on arrival, as the round-trip oracle can't
# see). ──────────────────────────────────────────────────────────────────────────
t6="$TMP/setu.out"
( # encrypt helper under set -u: must REACH its own precondition, not die at a `local`.
  # shellcheck source=/dev/null
  source "$ROOT/miuops" --source-only; set +e +o pipefail
  sops_encrypt_tunnel_cred no-such-tunnel-id ) >"$t6" 2>&1 || true
grep -qi 'unbound variable' "$t6"        && fail "sops_encrypt_tunnel_cred dies under set -u (local-order bug)"
grep -qi 'Tunnel credential not found' "$t6" || fail "sops_encrypt_tunnel_cred didn't reach its precondition: $(cat "$t6")"
( # provision helper under set -u
  # shellcheck source=/dev/null
  source "$ROOT/miuops" --source-only; set +e +o pipefail
  sops_provision_env no-such-server user@host ) >"$t6" 2>&1 || true
grep -qi 'unbound variable' "$t6"         && fail "sops_provision_env dies under set -u (local-order bug)"
grep -qi 'skipping .env provisioning' "$t6" || fail "sops_provision_env didn't reach its skip path: $(cat "$t6")"
echo "ok: sops helpers are set -u safe (reach own preconditions, never 'unbound variable')"

# ── 7. leak hygiene: NO per-function RETURN trap (never fires on die/set -e); the
# cleanup is NOT armed at top level (so sourcing the CLI can't clobber the sourcer's
# EXIT trap); and the cleanup actually shreds a registered temp. ──────────────────
grep -qE '^[[:space:]]*trap[^#]*RETURN' "$ROOT/miuops" && fail "a RETURN trap remains -- leaks the decrypted secret on die/set -e"
grep -qE '^trap[[:space:]]' "$ROOT/miuops" && fail "CLI arms a top-level trap -- would clobber a sourcer's EXIT trap"
grep -q 'trap _sops_cleanup EXIT INT TERM' "$ROOT/miuops" || fail "CLI must arm the sops cleanup on EXIT INT TERM"
(
  # shellcheck source=/dev/null
  source "$ROOT/miuops" --source-only
  lt="$(mktemp)"; _SOPS_TMPS=("$lt"); _sops_cleanup
  if [ -e "$lt" ]; then rm -f "$lt"; exit 3; fi
  exit 0
) || fail "_sops_cleanup did not shred a registered temp"
echo "ok: leak hygiene (no RETURN trap, no top-level trap, cleanup shreds registered temps)"

echo "ALL SOPS ORACLE TESTS PASSED"
