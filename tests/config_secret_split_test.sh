#!/usr/bin/env bash
# The config/secret split: in the observability + backup role defaults, CONFIG is
# versioned and SECRETS come from the SOPS-encrypted fleet (env is only a fallback).
#
#   CONFIG  (observability endpoints + user IDs, the backup region) -> role default
#           carries NO lookup('env'): it comes only from group_vars/all (endpoints)
#           or host_vars (region), and the role's `| length > 0` assert makes a
#           missing one fail LOUD, not silently ship an empty config.
#   SECRET  (the Grafana token, the AWS access key + secret) -> supplied at converge
#           from the SOPS-encrypted fleet (decrypted to --extra-vars, which outrank
#           defaults); the role default KEEPS a lookup('env') as the FALLBACK.
#
# This is a TRIPWIRE: it pins the split so a future edit can't silently re-mix a config
# value back onto env (re-introducing the conflation) or strip a secret's env fallback.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OBS="$ROOT/roles/observability/defaults/main.yml"
BAK="$ROOT/roles/backup/defaults/main.yml"
fail() { echo "FAIL: $1"; exit 1; }

# --- CONFIG must NOT env-lookup (versioned in group_vars/host_vars) ---
for v in grafana_cloud_prometheus_url grafana_cloud_prometheus_user \
         grafana_cloud_loki_url grafana_cloud_loki_user; do
    grep -qE "^${v}:.*lookup\(['\"]env" "$OBS" \
        && fail "${v} is CONFIG -> must not lookup('env') (set it in group_vars/all)"
done
grep -qE "^backup_aws_region:.*lookup\(['\"]env" "$BAK" \
    && fail "backup_aws_region is CONFIG -> must not lookup('env') (set it in host_vars)"

# --- SECRETS keep the env lookup as a FALLBACK (SOPS-in-fleet is the primary path) ---
grep -qE "^grafana_cloud_token:.*lookup\(['\"]env" "$OBS" \
    || fail "grafana_cloud_token is a SECRET -> keep the lookup('env') fallback"
grep -qE "^backup_aws_access_key_id:.*lookup\(['\"]env" "$BAK" \
    || fail "backup_aws_access_key_id is a SECRET -> keep the lookup('env') fallback"
grep -qE "^backup_aws_secret_access_key:.*lookup\(['\"]env" "$BAK" \
    || fail "backup_aws_secret_access_key is a SECRET -> keep the lookup('env') fallback"

echo "ALL CONFIG/SECRET SPLIT CHECKS PASSED"
