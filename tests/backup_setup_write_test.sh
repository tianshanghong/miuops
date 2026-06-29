#!/usr/bin/env bash
#
# CLI-mode (MIUOPS_FLEET_ROOT set) credential write + re-run semantics of
# setup-s3-backup.sh -- the integration of write_backup_secret into the real
# provisioning flow, behind a recording fake `aws` + a throwaway sops env:
#   * no key            -> mint a key and WRITE fleet/secrets/<s>.vars.json
#     (SOPS-encrypted), and NEVER print the secret;
#   * key + vars.json   -> no-op ("already set up");
#   * key, no vars.json -> refuse ("run backup-rotate") and write nothing, because
#     AWS does not return an existing key's secret.
#
# Real sops (throwaway age key); aws faked. Each case has a concrete assertion.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/setup-s3-backup.sh"
pass=0; fail=0
ok()  { printf 'ok   - %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL - %s\n' "$1"; fail=$((fail + 1)); }
command -v sops       >/dev/null 2>&1 || { echo "sops not installed" >&2; exit 1; }
command -v age-keygen >/dev/null 2>&1 || { echo "age-keygen not installed" >&2; exit 1; }

# $1 = has_key (0/1)  $2 = seed an existing vars.json (0/1). Echoes "<fleet_root> <rc>".
run() {
  local has_key="$1" seed="$2" root bin recip rc
  root="$(mktemp -d)"; bin="$(mktemp -d)"
  export SOPS_AGE_KEY_FILE="$root/keys.txt"
  age-keygen -o "$SOPS_AGE_KEY_FILE" 2>/dev/null
  recip="$(age-keygen -y "$SOPS_AGE_KEY_FILE")"
  mkdir -p "$root/fleet/secrets"
  cat > "$root/.sops.yaml" <<EOF
creation_rules:
  - path_regex: ^fleet/secrets/.*\.(json|env)\$
    age: ${recip}
EOF
  if [ "$seed" = 1 ]; then
    printf '{"backup_aws_access_key_id":"OLD","backup_aws_secret_access_key":"OLDSEC"}' \
      | ( cd "$root" && sops --encrypt --input-type json --output-type json \
            --filename-override fleet/secrets/web1.vars.json /dev/stdin ) > "$root/fleet/secrets/web1.vars.json"
  fi
  cat > "$bin/aws" <<REC
#!/usr/bin/env bash
case "\$1 \$2" in
  "sts get-caller-identity") echo '{"Arn":"arn:aws:iam::1:user/t"}' ;;
  "s3api head-bucket")       exit 0 ;;
  "iam get-user")            exit 1 ;;
  "iam list-access-keys")    $( [ "$has_key" = 1 ] && printf 'echo AKIAOLD' || printf 'echo ""' ) ;;
  "iam create-access-key")   echo '{"AccessKey":{"AccessKeyId":"AKIANEWID","SecretAccessKey":"AKIAnewSecret/xyz"}}' ;;
  *)                         : ;;
esac
exit 0
REC
  chmod +x "$bin/aws"
  rc=0
  ( PATH="$bin:$PATH" MIUOPS_BUCKET=wwang-fleet-backup MIUOPS_FLEET_ROOT="$root" \
      bash "$SCRIPT" --server web1 --region us-west-2 --yes </dev/null > "$root/out" 2>&1 ) || rc=$?
  rm -rf "$bin"
  printf '%s %s' "$root" "$rc"
}

# ── 1. no key -> mint + write encrypted; secret never printed ─────────────────
read -r root rc <<< "$(run 0 0)"
vj="$root/fleet/secrets/web1.vars.json"
{ [ -f "$vj" ] && grep -q 'ENC\[' "$vj"; } \
  && ok "no key: wrote an encrypted vars.json" || bad "no key: vars.json missing or not ciphertext"
{ [ "$rc" = 0 ]; } && ok "no key: exit 0" || bad "no key: exit $rc"
got="$( cd "$root" && SOPS_AGE_KEY_FILE="$root/keys.txt" sops -d --output-type json fleet/secrets/web1.vars.json 2>/dev/null | jq -r '.backup_aws_secret_access_key' )"
[ "$got" = "AKIAnewSecret/xyz" ] && ok "no key: round-trips to the freshly-minted secret" || bad "no key: round-trip mismatch (got '${got}')"
if grep -q 'AKIAnewSecret' "$root/out"; then bad "no key: the secret was PRINTED to stdout (leak)"; else ok "no key: secret not printed"; fi
rm -rf "$root"

# ── 2. key + vars.json already there -> no-op ─────────────────────────────────
read -r root rc <<< "$(run 1 1)"
{ [ "$rc" = 0 ] && grep -qi 'already set up' "$root/out"; } \
  && ok "key + vars.json: clean no-op (already set up)" || bad "key + vars.json: not a clean no-op (rc=$rc)"
rm -rf "$root"

# ── 3. key but NO vars.json -> refuse, write nothing, point to backup-rotate ──
read -r root rc <<< "$(run 1 0)"
{ [ "$rc" != 0 ] && grep -qi 'backup-rotate' "$root/out" && [ ! -f "$root/fleet/secrets/web1.vars.json" ]; } \
  && ok "key, no vars.json: refuses + points to backup-rotate + writes nothing" \
  || bad "key, no vars.json: did not refuse cleanly (rc=$rc)"
rm -rf "$root"

echo "== ${pass} passed, ${fail} failed =="
[ "$fail" -eq 0 ]
