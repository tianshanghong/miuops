#!/usr/bin/env bash
#
# `miuops backup-setup --server <h>` subcommand.
#
# The CLI owns fleet context, so it resolves the backup bucket from versioned
# config and hands it to the setup script as MIUOPS_BUCKET -- the script
# never re-prompts for a project / re-derives the bucket. The bucket is thus
# typed ONCE (in group_vars), killing the divergent-bucket footgun at the source.
#
# Verified WITHOUT real AWS by pointing MIUOPS_TEST_SCRIPT_DIR at a throwaway tool
# dir whose scripts/setup-s3-backup.sh is a recorder that captures MIUOPS_BUCKET
# and argv, then exits 0. Each assertion has a clear pass/fail.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf 'ok   - %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL - %s\n' "$1"; fail=$((fail + 1)); }

# Build a throwaway tool dir (fake scripts/setup-s3-backup.sh recorder) + fleet dir.
# Prints "the env line | the argv line" the recorder captured, or the CLI's stderr.
run_backup_setup() {
  local gv="$1"; shift              # group_vars/all.yml content ('' = none)
  local tool fleet rec
  tool="$(mktemp -d)"; fleet="$(mktemp -d)"; rec="$tool/rec"
  mkdir -p "$tool/scripts" "$fleet/fleet/group_vars"
  [ -n "$gv" ] && printf '%s\n' "$gv" > "$fleet/fleet/group_vars/all.yml"
  cat > "$tool/scripts/setup-s3-backup.sh" <<REC
#!/usr/bin/env bash
{ echo "BUCKET=\${MIUOPS_BUCKET:-<unset>}"; echo "ARGV=\$*"; } > "$rec"
exit 0
REC
  chmod +x "$tool/scripts/setup-s3-backup.sh"
  # The CLI must invoke the script under SCRIPT_DIR (overridden here for test).
  ( MIUOPS_TEST_SCRIPT_DIR="$tool" MIUOPS_FLEET_DIR="$fleet/fleet" \
      bash "$ROOT/miuops" backup-setup "$@" >/dev/null 2>"$tool/err" ) || true
  if [ -f "$rec" ]; then cat "$rec"; else printf 'NO_SCRIPT_CALL\n'; cat "$tool/err"; fi
  rm -rf "$tool" "$fleet"
}

# 1. resolves the fleet bucket from group_vars and passes it as MIUOPS_BUCKET
out="$(run_backup_setup 'backup_s3_bucket: wwang-fleet-backup' --server web1)"
printf '%s' "$out" | grep -q 'BUCKET=wwang-fleet-backup' \
  && ok "passes the resolved bucket as MIUOPS_BUCKET" \
  || bad "did not pass resolved bucket: $out"

# 2. forwards --server to the setup script
printf '%s' "$out" | grep -q -- '--server web1' \
  && ok "forwards --server to the setup script" \
  || bad "did not forward --server: $out"

# 3. NEGATIVE: no bucket in group_vars (first server / unconfigured) -> the CLI
#    must FAIL CLOSED with guidance, and must NOT invoke the setup script blind.
out="$(run_backup_setup '' --server web1)"
printf '%s' "$out" | grep -q 'NO_SCRIPT_CALL' \
  && ok "no fleet bucket -> does not invoke the setup script (fail-closed)" \
  || bad "ran setup with no bucket configured: $out"

# 4. --server with no value -> a clean die (not a raw bash unbound-variable crash),
#    and the setup script is never invoked.
out="$(run_backup_setup 'backup_s3_bucket: wwang-fleet-backup' --server)"
{ printf '%s' "$out" | grep -q 'NO_SCRIPT_CALL' && printf '%s' "$out" | grep -qi 'requires a value'; } \
  && ok "--server with no value fails closed with a clear message" \
  || bad "--server with no value did not fail cleanly: $out"

echo "== ${pass} passed, ${fail} failed =="
[ "$fail" -eq 0 ]
