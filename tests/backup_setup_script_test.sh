#!/usr/bin/env bash
#
# setup-s3-backup.sh consumes MIUOPS_BUCKET + skips shared-bucket
# config on reuse.
#
#   * MIUOPS_BUCKET set  -> the script uses that bucket and NEVER prompts for a
#     project (the CLI already resolved the fleet bucket from versioned config).
#   * bucket already exists (head-bucket succeeds) -> the script does NOT re-apply
#     the shared bucket-level config (create-bucket / encryption / public-access /
#     object-lock / lifecycle); it ONLY mints this server's IAM identity. Adding a
#     server can therefore never re-touch the shared fleet bucket.
#   * bucket does NOT exist (first server) -> the config IS applied (positive
#     control: the skip is conditional, not a blanket removal).
#
# Real script logic runs; only the `aws` boundary is faked by a PATH-shimmed
# recorder that logs every call and returns canned responses (no real AWS, no jq
# mocking). Each assertion has its mirror in the other branch so it can FAIL.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/setup-s3-backup.sh"
pass=0; fail=0
ok()  { printf 'ok   - %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL - %s\n' "$1"; fail=$((fail + 1)); }

# Run the real setup script with a recording fake `aws`. $1 = head-bucket mode:
#   exists -> bucket already there (rc 0); absent -> a real 404; error -> a NON-404
#   failure (403 / throttle). Echoes "<call-log-path> <script-exit-code>".
run_setup() {
  local mode="$1" bin log rc
  bin="$(mktemp -d)"; log="$bin/aws.log"
  cat > "$bin/aws" <<REC
#!/usr/bin/env bash
echo "\$*" >> "$log"
case "\$1 \$2" in
  "sts get-caller-identity")  echo '{"Arn":"arn:aws:iam::123456789012:user/tester"}' ;;
  "s3api head-bucket")
    case "$mode" in
      exists) exit 0 ;;
      absent) echo "An error occurred (404) when calling the HeadBucket operation: Not Found" >&2; exit 254 ;;
      error)  echo "An error occurred (403) when calling the HeadBucket operation: Forbidden" >&2; exit 254 ;;
    esac ;;
  "iam get-user")             exit 1 ;;   # NoSuchEntity -> script creates the user
  "iam list-access-keys")     echo "" ;;  # no existing key -> script creates one
  "iam create-access-key")    echo '{"AccessKey":{"AccessKeyId":"AKIAFAKE000000000000","SecretAccessKey":"fakeSecretValue/abc"}}' ;;
  *)                          : ;;        # create-user/put-user-policy/create-bucket/put-* -> log + succeed
esac
exit 0
REC
  chmod +x "$bin/aws"
  rc=0
  ( PATH="$bin:$PATH" MIUOPS_BUCKET="wwang-fleet-backup" \
      bash "$SCRIPT" --server web1 --region us-west-2 --yes </dev/null >/dev/null 2>&1 ) || rc=$?
  printf '%s %s' "$log" "$rc"
}

called()     { grep -q -- "$2" "$1"; }

# ── A. reuse path: bucket EXISTS -> only IAM, never re-touch the shared bucket ──
read -r log rc <<< "$(run_setup exists)"
called "$log" 'head-bucket --bucket wwang-fleet-backup' \
  && ok "uses MIUOPS_BUCKET (no project prompt; head-bucket on the resolved bucket)" \
  || bad "did not use MIUOPS_BUCKET / never reached head-bucket"

for op in create-bucket put-bucket-encryption put-object-lock-configuration put-bucket-lifecycle-configuration put-public-access-block; do
  if called "$log" "$op"; then bad "reuse re-touched the shared bucket: $op was called"; else ok "reuse skips shared-bucket op: $op"; fi
done

for op in 'iam put-user-policy' 'iam create-access-key'; do
  called "$log" "$op" && ok "reuse still mints IAM: $op" || bad "IAM not minted: $op missing"
done

# ── B. positive control: bucket does NOT exist (a real 404) -> config IS applied ─
read -r log rc <<< "$(run_setup absent)"
called "$log" 'create-bucket --bucket wwang-fleet-backup' \
  && ok "absent (404) bucket is created" || bad "absent bucket not created"
called "$log" 'put-bucket-encryption' \
  && ok "fresh bucket gets its config (skip is conditional, not blanket)" \
  || bad "fresh bucket did not get encryption config"

# ── C. a NON-404 head-bucket failure (transient/403) must fail closed: NEVER ──
#       create or re-touch a bucket it cannot confirm absent, never mint IAM blind. ─
read -r log rc <<< "$(run_setup error)"
{ [ "$rc" -ne 0 ] && ok "non-404 head-bucket error fails closed (rc=$rc)"; } || bad "non-404 error did not fail closed (rc=$rc)"
for op in create-bucket put-bucket-encryption put-object-lock-configuration put-bucket-lifecycle-configuration 'iam create-user' 'iam create-access-key'; do
  if called "$log" "$op"; then bad "non-404 error still ran '$op' (touched/minted on an unconfirmed bucket)"; else ok "non-404 error skips '$op'"; fi
done

echo "== ${pass} passed, ${fail} failed =="
[ "$fail" -eq 0 ]
