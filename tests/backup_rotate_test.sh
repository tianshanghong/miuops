#!/usr/bin/env bash
#
# `miuops backup-rotate --server <h>` — the safe key-rotation sequence:
#   * refuse unless the IAM user has EXACTLY 1 access key (0 -> backup-setup; 2 ->
#     resolve the extra key first), so a rotation is never ambiguous;
#   * order is create-new -> write-(merged)-into-vars.json -> miuops apply ->
#     and ONLY on apply success, delete the OLD key;
#   * if apply fails, abort BEFORE the delete -- the host keeps a working key, so a
#     failed rotation never leaves the server unable to back up.
#
# cmd_backup_rotate is exercised with the AWS boundary faked (a PATH-shimmed aws
# that records create/delete) and write_backup_secret + run_apply stubbed to
# recorders, so the test pins the SEQUENCE + the abort-before-delete safety without
# real AWS / sops / a converge.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf 'ok   - %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL - %s\n' "$1"; fail=$((fail + 1)); }

# run_rotate <num-existing-keys 0/1/2> <apply-rc 0/1>  -> echoes "<log> <exit-code>"
run_rotate() {
  local nkeys="$1" apply_rc="$2" fleet bin log rc list
  # NB: keep the brace-laden JSON OUT of ${3:-...} -- bash's brace matching inside the
  # parameter expansion mangles a provided $3 (appends stray braces), which silently
  # corrupted case 5's input.
  local create_resp="${3:-}"
  [ -n "$create_resp" ] || create_resp='{"AccessKey":{"AccessKeyId":"AKIANEW","SecretAccessKey":"new/sec+val"}}'
  fleet="$(mktemp -d)"; bin="$(mktemp -d)"; log="$fleet/log"; : > "$log"
  mkdir -p "$fleet/fleet/group_vars"
  echo 'backup_s3_bucket: wwang-fleet-backup' > "$fleet/fleet/group_vars/all.yml"
  case "$nkeys" in
    0) list='echo ""' ;;
    1) list='echo AKIAOLD1' ;;
    2) list='printf "AKIAOLD1\tAKIAOLD2\n"' ;;
  esac
  cat > "$bin/aws" <<REC
#!/usr/bin/env bash
case "\$1 \$2" in
  "iam list-access-keys")  ${list} ;;
  "iam create-access-key") echo "CREATE \$*" >> "${log}"; echo '${create_resp}' ;;
  "iam delete-access-key") echo "DELETE \$*" >> "${log}" ;;
  *) : ;;
esac
exit 0
REC
  chmod +x "$bin/aws"
  rc=0
  ( PATH="$bin:$PATH" MIUOPS_FLEET_DIR="$fleet/fleet" bash -c '
      . "'"$ROOT"'/miuops" --source-only 2>/dev/null
      require_sops()        { :; }   # the sops binary is a converge dep, not needed to unit-test the rotation flow (CI lint stage has no sops)
      write_backup_secret() { echo "WRITE $2" >> "'"$log"'"; return 0; }
      run_apply()           { echo "APPLY $*" >> "'"$log"'"; return '"$apply_rc"'; }
      cmd_backup_rotate --server web1 --yes
    ' >/dev/null 2>>"$log" ) || rc=$?
  rm -rf "$bin"
  printf '%s %s' "$log" "$rc"
}

seq_of() { grep -oE 'CREATE|WRITE|APPLY|DELETE' "$1" | tr '\n' ' '; }

# 1. exactly 1 key + apply OK -> full sequence, old key deleted, exit 0
read -r log rc <<< "$(run_rotate 1 0)"
[ "$(seq_of "$log")" = "CREATE WRITE APPLY DELETE " ] \
  && ok "happy path: create -> write -> apply -> delete, in order" \
  || bad "happy path wrong sequence: '$(seq_of "$log")'"
grep -q 'DELETE .*AKIAOLD1' "$log" && ok "deletes the OLD key (AKIAOLD1)" || bad "did not delete the old key"
{ [ "$rc" = 0 ]; } && ok "happy path exit 0" || bad "happy path exit $rc"
rm -rf "$(dirname "$log")"

# 2. apply FAILS -> abort BEFORE delete (old key kept), non-zero exit
read -r log rc <<< "$(run_rotate 1 1)"
if grep -q 'DELETE' "$log"; then bad "apply failed but the OLD key was STILL deleted (unsafe)"; else ok "apply failure aborts BEFORE delete (old key kept)"; fi
grep -q 'CREATE' "$log" && grep -q 'APPLY' "$log" && ok "apply-fail path still created + tried apply" || bad "apply-fail path did not reach apply"
{ [ "$rc" != 0 ]; } && ok "apply failure exits non-zero" || bad "apply failure did not fail (rc=$rc)"
rm -rf "$(dirname "$log")"

# 3. zero keys -> refuse (use backup-setup), nothing created/deleted
read -r log rc <<< "$(run_rotate 0 0)"
{ [ "$rc" != 0 ] && [ -z "$(seq_of "$log")" ] && grep -qi 'backup-setup' "$log"; } \
  && ok "0 keys: refuses + points to backup-setup, creates/deletes nothing" \
  || bad "0 keys: did not refuse cleanly (rc=$rc seq='$(seq_of "$log")')"
rm -rf "$(dirname "$log")"

# 4. two keys -> refuse (ambiguous), nothing created/deleted
read -r log rc <<< "$(run_rotate 2 0)"
{ [ "$rc" != 0 ] && [ -z "$(seq_of "$log")" ]; } \
  && ok "2 keys: refuses (ambiguous), creates/deletes nothing" \
  || bad "2 keys: did not refuse cleanly (rc=$rc seq='$(seq_of "$log")')"
rm -rf "$(dirname "$log")"

# 5. a malformed-but-successful create-access-key response where jq returns "null"
#    WITHOUT erroring (so set -e does NOT catch it) -> the guard must abort BEFORE
#    write/apply/delete, so the old key is never touched (safety invariant stays total).
read -r log rc <<< "$(run_rotate 1 0 '{"AccessKey":{}}')"
{ [ "$rc" != 0 ] && grep -q 'CREATE' "$log" && ! grep -qE 'WRITE|APPLY|DELETE' "$log"; } \
  && ok "malformed create response: aborts before write/apply/delete (old key untouched)" \
  || bad "malformed create: did not abort cleanly (rc=$rc seq='$(seq_of "$log")')"
rm -rf "$(dirname "$log")"

echo "== ${pass} passed, ${fail} failed =="
[ "$fail" -eq 0 ]
