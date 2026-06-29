#!/usr/bin/env bash
#
# The adopter template teaches the single-source-of-truth backup pattern: the shared
# bucket (+ client-side encryption mode + age recipients) lives ONCE in
# group_vars/all.yml.example, and is NOT duplicated into host_vars/server1.yml.example
# (which carries only the per-server switch + volume list). A future template edit
# that re-scatters the shared bucket into host_vars trips this lint.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GV="$ROOT/group_vars/all.yml.example"
HV="$ROOT/host_vars/server1.yml.example"
pass=0; fail=0
ok()  { printf 'ok   - %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL - %s\n' "$1"; fail=$((fail + 1)); }

# Shared backup config -> group_vars example (single source).
for k in backup_s3_bucket backup_encryption backup_age_recipients; do
  grep -qE "^[# ]*${k}:" "$GV" && ok "group_vars example shows fleet-wide '${k}'" \
    || bad "group_vars/all.yml.example is missing fleet-wide '${k}'"
done

# Per-server backup config -> host_vars example (the switch + volumes).
for k in backup_enabled backup_volumes; do
  grep -qE "^[# ]*${k}:" "$HV" && ok "host_vars example shows per-server '${k}'" \
    || bad "host_vars/server1.yml.example is missing per-server '${k}'"
done

# The shared bucket must NOT be duplicated into the host_vars example (the anti-pattern
# this consolidation removes). An ACTIVE (uncommented) line is the failure.
if grep -qE '^[[:space:]]*backup_s3_bucket:' "$HV"; then
  bad "host_vars/server1.yml.example duplicates the fleet-wide backup_s3_bucket (belongs in group_vars)"
else
  ok "host_vars example does not duplicate the fleet-wide bucket"
fi

# The role's own README must teach the SAME split (bucket under group_vars, fleet-wide),
# not the old bucket-in-host_vars schema/example.
if grep -qF 'group_vars/all.yml — fleet-wide' "$ROOT/roles/backup/README.md"; then
  ok "roles/backup/README.md shows the bucket under group_vars (fleet-wide)"
else
  bad "roles/backup/README.md does not show the bucket as fleet-wide/group_vars (teaches the anti-pattern)"
fi

echo "== ${pass} passed, ${fail} failed =="
[ "$fail" -eq 0 ]
