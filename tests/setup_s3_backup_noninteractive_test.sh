#!/usr/bin/env bash
# Verifies setup-s3-backup.sh runs non-interactively: --yes/--region (and the mirror
# env vars MIUOPS_ASSUME_YES/MIUOPS_REGION) skip the prompts, while a non-interactive
# shell WITHOUT --yes fails closed (refuses, creating nothing). `aws` is mocked so no
# real AWS call ever happens — the credential check passes and any other call is
# refused-and-recorded, which proves the script got PAST the prompts without creating
# resources.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/setup-s3-backup.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

cat > "$TMP/aws" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *"get-caller-identity"* ]]; then echo "arn:aws:iam::000000000000:user/Mock"; exit 0; fi
echo "mock-aws-call: $*" >&2; exit 1
SH
chmod +x "$TMP/aws"

# 1. --yes + --region: both prompts skipped, reaches a real (mocked) AWS call.
out="$(PATH="$TMP:$PATH" bash "$SCRIPT" --project tx --server ty --region us-west-2 --yes </dev/null 2>&1 || true)"
if ! printf '%s' "$out" | grep -q 'mock-aws-call:'; then
  fail "--yes did not run non-interactively (never reached an AWS call): $out"
fi
if printf '%s' "$out" | grep -qiE 'Continue\?|Enter AWS region'; then
  fail "--yes still printed an interactive prompt"
fi
echo "ok: --yes --region runs non-interactively (skips both prompts)"

# 2. env vars mirror the flags.
out="$(PATH="$TMP:$PATH" MIUOPS_PROJECT=tx MIUOPS_SERVER=ty MIUOPS_REGION=us-west-2 MIUOPS_ASSUME_YES=true \
        bash "$SCRIPT" </dev/null 2>&1 || true)"
if ! printf '%s' "$out" | grep -q 'mock-aws-call:'; then
  fail "MIUOPS_ASSUME_YES/MIUOPS_REGION env did not run non-interactively: $out"
fi
echo "ok: MIUOPS_ASSUME_YES + MIUOPS_REGION env mirror the flags"

# 3. non-interactive WITHOUT --yes: refuse clearly, create nothing (fail closed).
out="$(PATH="$TMP:$PATH" bash "$SCRIPT" --project tx --server ty --region us-west-2 </dev/null 2>&1 || true)"
if ! printf '%s' "$out" | grep -qi 'Refusing to proceed'; then
  fail "non-interactive without --yes did not refuse clearly: $out"
fi
if printf '%s' "$out" | grep -q 'mock-aws-call:'; then
  fail "non-interactive without --yes still reached an AWS call (not fail-closed)"
fi
echo "ok: non-interactive without --yes fails closed (no resources created)"

echo "ALL SETUP-S3-BACKUP NON-INTERACTIVE TESTS PASSED"
