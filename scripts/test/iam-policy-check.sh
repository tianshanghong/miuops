#!/usr/bin/env bash
#
# Check for the per-server backup IAM policy emitted by scripts/setup-s3-backup.sh.
#
# It GENERATES the inline policy for a sample bucket + server (by sourcing the
# setup script and calling its gen_iam_policy function), then asserts the exact
# prefix-scoped, Allow-only shape required by the fleet contract:
#
#   * s3:ListBucket  -> Resource arn:aws:s3:::<bucket>  (bucket-level, no /*)
#                       Condition StringLike s3:prefix == ["<server>/*"]
#   * s3:PutObject + s3:GetObject (and ONLY those) -> Resource
#                       arn:aws:s3:::<bucket>/<server>/*  (object-level)
#   * NO s3:DeleteObject anywhere
#   * NO "s3:*" wildcard anywhere
#   * NO Deny statement anywhere
#   * POSITIVE control: an own-prefix PutObject resource is present.
#
# Every assertion is paired with a negative fixture (a deliberately-bad policy)
# proving it can FAIL, so a green run is meaningful. Pure structural checks via
# jq; no AWS calls, so it runs in CI with no credentials.
#
# Exit 0 = all assertions held (and every negative fixture genuinely failed).
# Exit 1 = a contract assertion failed (or a negative fixture did NOT fail).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_SCRIPT="${SCRIPT_DIR}/../setup-s3-backup.sh"

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq is required" >&2; exit 2; }
[ -f "$SETUP_SCRIPT" ] || { echo "FATAL: setup script not found at $SETUP_SCRIPT" >&2; exit 2; }

# Source the setup script in "library" mode: it must define gen_iam_policy and
# return WITHOUT running the interactive bucket/IAM flow.
# shellcheck source=/dev/null
MIUOPS_S3_SETUP_LIB=1 . "$SETUP_SCRIPT"

if ! declare -F gen_iam_policy >/dev/null 2>&1; then
  echo "FATAL: setup-s3-backup.sh did not define gen_iam_policy (library mode)" >&2
  exit 2
fi

SAMPLE_BUCKET="myfleet-backup"
SAMPLE_SERVER="web1"
OTHER_SERVER="web2"

POLICY="$(gen_iam_policy "$SAMPLE_BUCKET" "$SAMPLE_SERVER")"

# --- tiny assert harness ----------------------------------------------------
pass=0
fail=0
ok()   { printf 'ok   - %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf 'FAIL - %s\n' "$1"; fail=$((fail + 1)); }

# assert_eq <description> <actual> <expected>
assert_eq() {
  if [ "$2" = "$3" ]; then ok "$1 (= '$3')"; else bad "$1: got '$2' expected '$3'"; fi
}
# assert_true_jq <description> <policy-json> <jq-filter-that-should-exit-0>
assert_true_jq() {
  if printf '%s' "$2" | jq -e "$3" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi
}
# assert_false_jq <description> <policy-json> <jq-filter-that-should-exit-NONZERO>
assert_false_jq() {
  if printf '%s' "$2" | jq -e "$3" >/dev/null 2>&1; then bad "$1 (filter unexpectedly matched)"; else ok "$1"; fi
}

# jq filters (reused for real policy AND bad fixtures so each can FAIL) --------
F_VALID_JSON='type=="object"'
F_OBJ_RESOURCE='[.Statement[]|select(.Action|tostring|test("PutObject"))|.Resource]|flatten|.[0]'
F_LIST_RESOURCE='[.Statement[]|select((.Action|tostring)=="s3:ListBucket")|.Resource]|flatten|.[0]'
F_LIST_PREFIX='[.Statement[]|select((.Action|tostring)=="s3:ListBucket")|.Condition.StringLike."s3:prefix"]|flatten|.[0]'
# object actions, sorted+uniqued, must be EXACTLY [GetObject, PutObject]
F_OBJ_ACTIONS_EXACT='([.Statement[]|select(.Resource|tostring|test("/'"$SAMPLE_SERVER"'/\\*"))|.Action]|flatten|sort|unique)==["s3:GetObject","s3:PutObject"]'
# Pattern-based so variant/wildcard forms (s3:Delete*, s3:*Object, s3:DeleteObjectVersion,
# s3:*) are caught across ALL statements, not only the exact "s3:DeleteObject"/"s3:*" strings.
F_HAS_DELETE='[.Statement[].Action]|flatten|any(ascii_downcase|test("delete"))'
F_HAS_WILDCARD='[.Statement[].Action]|flatten|any(test("[*]"))'
# Strongest guard: the COMPLETE set of actions must be a subset of the three allowed ones,
# so ANY unexpected action (a delete, a wildcard, a new grant) trips it.
F_ACTIONS_SUBSET='(([.Statement[].Action]|flatten|unique)-["s3:GetObject","s3:ListBucket","s3:PutObject"])|length==0'
F_HAS_DENY='[.Statement[].Effect]|any(.=="Deny")'
F_HAS_OWN_PUT='[.Statement[]|select(.Resource|tostring|test("/'"$SAMPLE_SERVER"'/\\*"))|.Action]|flatten|any(.=="s3:PutObject")'

echo "== generated policy for bucket=$SAMPLE_BUCKET server=$SAMPLE_SERVER =="
printf '%s\n' "$POLICY"
echo "== assertions =="

# 1. valid, parseable IAM JSON
assert_true_jq "policy is valid parseable JSON object" "$POLICY" "$F_VALID_JSON"

# 2. object actions scoped to own prefix ARN
assert_eq "object Resource is own-prefix ARN" \
  "$(printf '%s' "$POLICY" | jq -r "$F_OBJ_RESOURCE")" \
  "arn:aws:s3:::${SAMPLE_BUCKET}/${SAMPLE_SERVER}/*"

# 3. object actions are EXACTLY PutObject + GetObject (no more)
assert_true_jq "object actions are exactly Put+Get" "$POLICY" "$F_OBJ_ACTIONS_EXACT"

# 4. ListBucket is bucket-level (no /*)
assert_eq "ListBucket Resource is bare bucket ARN" \
  "$(printf '%s' "$POLICY" | jq -r "$F_LIST_RESOURCE")" \
  "arn:aws:s3:::${SAMPLE_BUCKET}"

# 5. ListBucket prefix Condition is StringLike "<server>/*"
assert_eq "ListBucket Condition s3:prefix == <server>/*" \
  "$(printf '%s' "$POLICY" | jq -r "$F_LIST_PREFIX")" \
  "${SAMPLE_SERVER}/*"

# 6. NO DeleteObject
assert_false_jq "no s3:DeleteObject anywhere" "$POLICY" "$F_HAS_DELETE"

# 7. NO s3:* wildcard (any form)
assert_false_jq "no s3:* wildcard anywhere" "$POLICY" "$F_HAS_WILDCARD"

# 7b. STRONGEST: every action is within {ListBucket, GetObject, PutObject} — catches any
# extra/variant grant (e.g. s3:Delete*, s3:*Object) that the specific guards above might miss.
assert_true_jq "all actions are within the allowed set" "$POLICY" "$F_ACTIONS_SUBSET"

# 8. NO Deny statement
assert_false_jq "no Deny statement anywhere" "$POLICY" "$F_HAS_DENY"

# 9. POSITIVE control: own-prefix PutObject resource present
assert_true_jq "POSITIVE: own-prefix PutObject is present" "$POLICY" "$F_HAS_OWN_PUT"

# 10. cross-server isolation: the OTHER server's prefix is NOT writable by this policy
assert_false_jq "no other-server (${OTHER_SERVER}/*) object resource" "$POLICY" \
  '[.Statement[]|select(.Resource|tostring|test("/'"$OTHER_SERVER"'/\\*"))]|length>0'

# --- negative fixtures: prove each assertion CAN fail ------------------------
# A bad policy that regressed to bucket-wide + added Delete + a Deny + s3:*.
# Running the SAME filters against it must flip every result; if any of these
# "negative" checks passes against the bad fixture, the check itself is broken.
echo "== negative fixtures (each must trip the matching assertion) =="
BAD_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": "s3:ListBucket", "Resource": "arn:aws:s3:::${SAMPLE_BUCKET}/*" },
    { "Effect": "Allow", "Action": ["s3:PutObject","s3:GetObject","s3:DeleteObject","s3:*"],
      "Resource": "arn:aws:s3:::${SAMPLE_BUCKET}/*" },
    { "Effect": "Deny", "Action": "s3:GetObject", "Resource": "arn:aws:s3:::${SAMPLE_BUCKET}/${OTHER_SERVER}/*" }
  ]
}
EOF
)

neg_ok=0
neg_bad=0
# neg_expect_true  <desc> <cmd...>   : cmd MUST succeed against the bad fixture.
# neg_expect_false <desc> <cmd...>   : cmd MUST fail   against the bad fixture.
neg_expect_true() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "ok   - $desc"; neg_ok=$((neg_ok + 1))
  else echo "FAIL - $desc (expected to detect, did not)"; neg_bad=$((neg_bad + 1)); fi
}
neg_expect_false() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "FAIL - $desc (unexpected match)"; neg_bad=$((neg_bad + 1))
  else echo "ok   - $desc"; neg_ok=$((neg_ok + 1)); fi
}
# Invoked indirectly via neg_expect_* (passed as "$@"); shellcheck can't see that.
# shellcheck disable=SC2329
jq_on_bad() { printf '%s' "$BAD_POLICY" | jq -e "$1"; }

# For the bad policy: the object Resource is bucket-wide (so the own-prefix ARN
# filter must NOT find it), delete/wildcard/deny filters MUST match, and the
# prefix Condition is absent.
neg_expect_false "bad fixture: object Resource is NOT own-prefix" \
  jq_on_bad "$F_OBJ_RESOURCE|tostring==\"arn:aws:s3:::${SAMPLE_BUCKET}/${SAMPLE_SERVER}/*\""
neg_expect_true  "bad fixture: DeleteObject detected"        jq_on_bad "$F_HAS_DELETE"
neg_expect_true  "bad fixture: s3:* detected"                jq_on_bad "$F_HAS_WILDCARD"
neg_expect_true  "bad fixture: Deny detected"                jq_on_bad "$F_HAS_DENY"
neg_expect_false "bad fixture: missing prefix Condition"     jq_on_bad "$F_LIST_PREFIX|tostring!=\"null\""
# The four assertions that previously lacked a negative fixture (3, 4, 7b, 9, 10):
neg_expect_false "bad fixture: object actions NOT exactly Put+Get"     jq_on_bad "$F_OBJ_ACTIONS_EXACT"
neg_expect_false "bad fixture: ListBucket Resource NOT bare bucket"    jq_on_bad "$F_LIST_RESOURCE|tostring==\"arn:aws:s3:::${SAMPLE_BUCKET}\""
neg_expect_true  "bad fixture: actions escape the allowed set"         jq_on_bad "($F_ACTIONS_SUBSET)|not"
neg_expect_false "bad fixture: own-prefix PutObject absent"            jq_on_bad "$F_HAS_OWN_PUT"
neg_expect_true  "bad fixture: other-server (${OTHER_SERVER}/*) resource present" \
  jq_on_bad "[.Statement[]|select(.Resource|tostring|test(\"/${OTHER_SERVER}/[*]\"))]|length>0"

# --- summary ----------------------------------------------------------------
echo "== summary =="
echo "positive assertions: ${pass} ok, ${fail} fail"
echo "negative fixtures:   ${neg_ok} ok, ${neg_bad} fail"
if [ "$fail" -ne 0 ] || [ "$neg_bad" -ne 0 ]; then
  echo "IAM POLICY CHECK: FAIL"
  exit 1
fi
echo "IAM POLICY CHECK: PASS"
exit 0
