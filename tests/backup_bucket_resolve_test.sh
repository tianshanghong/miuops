#!/usr/bin/env bash
#
# CLI single-source-of-truth bucket resolver: resolve_backup_bucket <host>.
#
# The fleet's backup bucket name is CONFIG with ONE home (versioned vars), so a
# server is never onboarded against a re-typed/typo'd bucket. The CLI resolves it
# from group_vars/all.yml, with host_vars/<host>.yml overriding, and passes it to
# the setup script -- the script never re-derives it from a --project prompt.
#
# This test pins the parse contract, each assertion with a NEGATIVE fixture so it
# can FAIL (the YAML-by-grep footgun: bash mismatching on comments/quoting --
# the exact class of bug fixed before in obs_opted_out).
#
# Sources the CLI in --source-only mode (no main run) and calls the function with
# a per-case throwaway FLEET_DIR.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf 'ok   - %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL - %s\n' "$1"; fail=$((fail + 1)); }

# Run resolve_backup_bucket <host> against a freshly-built fleet fixture.
# Usage: resolve <host> <group_vars-content> <host_vars-content>
resolve() {
  local host="$1" gv="$2" hv="$3" dir
  dir="$(mktemp -d)"
  mkdir -p "$dir/fleet/group_vars" "$dir/fleet/host_vars"
  printf '%s\n' "$gv" > "$dir/fleet/group_vars/all.yml"
  [ -n "$hv" ] && printf '%s\n' "$hv" > "$dir/fleet/host_vars/${host}.yml"
  ( MIUOPS_FLEET_DIR="$dir/fleet" bash -c '
      . '"$ROOT"'/miuops --source-only 2>/dev/null
      resolve_backup_bucket "'"$host"'"
    ' )
  rm -rf "$dir"
}

# assert_resolve <desc> <host> <gv> <hv> <expected>
assert_resolve() {
  local got; got="$(resolve "$2" "$3" "$4")"
  if [ "$got" = "$5" ]; then ok "$1 (-> '${5}')"; else bad "$1: got '${got}' expected '${5}'"; fi
}

# 1. group_vars only
assert_resolve "group_vars value resolves" web1 \
  'backup_s3_bucket: "myfleet-backup"' '' 'myfleet-backup'

# 2. host_vars OVERRIDES group_vars
assert_resolve "host_vars overrides group_vars" web1 \
  'backup_s3_bucket: "fleetwide-backup"' 'backup_s3_bucket: "host-specific-backup"' 'host-specific-backup'

# 3. quoting variants all yield the bare value
assert_resolve "double-quoted" web1 'backup_s3_bucket: "q-backup"'  '' 'q-backup'
assert_resolve "single-quoted" web1 "backup_s3_bucket: 'q-backup'"  '' 'q-backup'
assert_resolve "unquoted"      web1 'backup_s3_bucket: q-backup'     '' 'q-backup'

# 4. leading whitespace + trailing inline comment are tolerated/stripped
assert_resolve "inline comment stripped" web1 \
  'backup_s3_bucket: real-backup   # the fleet bucket' '' 'real-backup'

# 5. NEGATIVE: a commented-out key must NOT resolve (-> empty)
assert_resolve "commented-out key does not resolve" web1 \
  '# backup_s3_bucket: ghost-backup' '' ''

# 6. NEGATIVE: the key as a substring inside a comment must NOT match
assert_resolve "substring-in-comment does not match" web1 \
  '# remember to set backup_s3_bucket later' '' ''

# 7. NEGATIVE: unset anywhere -> empty (so callers can detect "first server / not configured")
assert_resolve "missing -> empty" web1 'observability_enabled: true' '' ''

# 8. host_vars present but WITHOUT the key falls back to group_vars
assert_resolve "host_vars without key falls back to group_vars" web1 \
  'backup_s3_bucket: fleetwide-backup' 'domains: ["x.com"]' 'fleetwide-backup'

# --- backfilled from adversarial review (grep-isn't-a-YAML-parser footguns) ---
# 9. NEGATIVE: a same-named key NESTED under another map is NOT the fleet bucket
#    (an indented key belongs to a parent) -> must resolve empty, not the nested value.
assert_resolve "nested key under another map does not resolve" web1 \
  "$(printf 'some_block:\n  backup_s3_bucket: nested-not-fleet')" '' ''

# 10. a nested decoy BEFORE the real top-level key must NOT win (column-0 anchor).
assert_resolve "top-level wins over an earlier nested decoy" web1 \
  "$(printf 'some_block:\n  backup_s3_bucket: nested-decoy\nbackup_s3_bucket: toplevel-real')" '' 'toplevel-real'

# 11. duplicate top-level keys -> LAST wins (YAML/Ansible last-key-wins; CLI must agree).
assert_resolve "duplicate top-level key resolves to the LAST" web1 \
  "$(printf 'backup_s3_bucket: first-dup\nbackup_s3_bucket: last-dup')" '' 'last-dup'

# 12. a stray NUL byte must not make grep emit "Binary file ... matches" as the bucket.
nul_dir="$(mktemp -d)"
mkdir -p "$nul_dir/fleet/group_vars"
printf 'backup_s3_bucket: real-backup\nnote: junk\000corrupt\n' > "$nul_dir/fleet/group_vars/all.yml"
nul_got="$( MIUOPS_FLEET_DIR="$nul_dir/fleet" bash -c '. '"$ROOT"'/miuops --source-only 2>/dev/null; resolve_backup_bucket web1' )"
if [ "$nul_got" = "real-backup" ]; then ok "NUL byte in file does not corrupt the resolved bucket (-> 'real-backup')"
else bad "NUL byte: got '${nul_got}' expected 'real-backup'"; fi
rm -rf "$nul_dir"

echo "== ${pass} passed, ${fail} failed =="
[ "$fail" -eq 0 ]
