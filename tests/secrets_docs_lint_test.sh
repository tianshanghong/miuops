#!/usr/bin/env bash
# docs/SECRETS.md is the operator-facing secret model. Pin it to reality so it can't
# drift from the code: the deployed-secret FILES it documents must be the ones the CLI
# decrypts, the VARS it names must be the ones the roles read, and the Cloudflare token
# must stay documented as operator-local (never in the fleet).
#
# A TRIPWIRE, not a proof: it catches the realistic drift -- a renamed secret file, a
# renamed var, or the doc silently dropping the operator-local stance.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOC="$ROOT/docs/SECRETS.md"
CLI="$ROOT/miuops"
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$DOC" ] || fail "docs/SECRETS.md is missing (the secret-model doc)"

# All three classes have a section.
grep -qiE '^##.*config'          "$DOC" || fail "SECRETS.md must have a config-class section"
grep -qiE '^##.*deployed secret' "$DOC" || fail "SECRETS.md must have a deployed-secret section"
grep -qiE '^##.*operator token'  "$DOC" || fail "SECRETS.md must have an operator-token section"

# The deployed-secret FILES the doc names are the ones run_apply actually decrypts.
grep -qF 'all.vars.json'    "$DOC" || fail "SECRETS.md must document fleet/secrets/all.vars.json"
grep -qF '<host>.vars.json' "$DOC" || fail "SECRETS.md must document fleet/secrets/<host>.vars.json"
grep -qF 'all.vars.json'    "$CLI" || fail "doc names all.vars.json but the CLI does not read it"
grep -qF '${host}.vars.json' "$CLI" || fail "doc names <host>.vars.json but the CLI does not read \${host}.vars.json"

# The VARS the doc names are the ones the roles read (no phantom var in the doc).
grep -qF 'grafana_cloud_token' "$DOC" \
    && grep -qrF 'grafana_cloud_token' "$ROOT/roles/observability" \
    || fail "grafana_cloud_token must appear in BOTH SECRETS.md and the observability role"
grep -qF 'backup_aws_access_key_id' "$DOC" \
    && grep -qrF 'backup_aws_access_key_id' "$ROOT/roles/backup" \
    || fail "backup_aws_access_key_id must appear in BOTH SECRETS.md and the backup role"

# The Cloudflare token is documented as operator-local, NOT in the fleet.
grep -qF 'CF_API_TOKEN'   "$DOC" || fail "SECRETS.md must name CF_API_TOKEN"
grep -qiF 'operator-local' "$DOC" || fail "SECRETS.md must state CF_API_TOKEN stays operator-local (not in the fleet)"
# The CF token is DNS-only -- the tunnel is created via the cloudflared binary, not this
# API token. Pin the correct scope so the doc can't regress to granting tunnel perms.
grep -qiE 'edit zone dns|zone:read' "$DOC" \
    || fail "SECRETS.md must scope CF_API_TOKEN to DNS (the 'Edit zone DNS' template / Zone:Read); it needs NO tunnel perms (tunnel = cloudflared, not the token)"

echo "ALL SECRETS DOCS LINT CHECKS PASSED"
