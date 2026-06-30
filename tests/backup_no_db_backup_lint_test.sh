#!/usr/bin/env bash
#
# grep-clean acceptance gate for the WAL-G retirement.
#
# miuOps does NOT self-manage database backups: databases are outsourced to managed
# Postgres (the app sets DATABASE_URL). After retirement, no tracked, shipped file may
# carry a DANGLING reference to the retired self-managed DB-backup artifacts -- the
# `postgres-walg` image, the `WALG_*` env, the `walg-backup` script, or the `db/` S3
# backup prefix. Volume backups (the host `backup` role -> `<server>/vol/`) are the only
# miuOps-managed backup and are untouched by this gate.
#
# EXCLUDED from the scan (they legitimately name the terms). The scan walks
# `git ls-files`, so git-ignored paths (docs/superpowers/, tests/e2e/) are already
# omitted — these EXCLUDE entries are belt-and-suspenders should they ever be tracked:
#   - this test itself (it spells out the patterns)
#   - docs/superpowers/  (local planning docs that DESCRIBE the removal)
#   - tests/e2e/backup-consolidation-acceptance.sh (asserts these are ABSENT at runtime)
# Managed-Postgres guidance prose may say "WAL-G" with a hyphen (we don't do it); the
# pattern targets the artifact spellings (walg / postgres-walg / db prefix), not prose.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

PATTERN='wal-?g|s3://[^ ]*/db/|<server>/db/'   # retired-artifact footprint: WAL-G (all spellings) + the S3 'db/' backup prefix, anchored to an s3:// URL or the <server> placeholder so it can't false-match an unrelated filesystem path (lib/db/, /srv/db/). Case-insensitive (-i).
EXCLUDE='^(tests/backup_no_db_backup_lint_test\.sh|tests/e2e/backup-consolidation-acceptance\.sh|docs/superpowers/)'

hits="$(git ls-files | grep -vE "$EXCLUDE" | while IFS= read -r f; do
  grep -IniE "$PATTERN" "$f" 2>/dev/null | sed "s|^|${f}:|"
done)"

if [ -n "$hits" ]; then
  echo "FAIL - dangling retired-DB-backup references (WAL-G / postgres-walg / db prefix):"
  printf '%s\n' "$hits" | sed 's/^/  /'
  echo "== grep-clean FAILED =="
  exit 1
fi
echo "== grep-clean: no dangling WAL-G / postgres-walg / db-prefix refs =="
