#!/usr/bin/env bash
# The observability role is ON by default (observability_enabled: true) but must
# ACTIVATE gracefully: enabled-but-unconfigured SKIPS with a warning, never a converge
# failure -- so a default-on fleet that hasn't set up Grafana Cloud still converges. A
# PARTIAL config (the endpoint set but token/other endpoints missing) still fails the
# assert.
#
# This is a TRIPWIRE pinning that contract so a future edit can't (a) flip the default
# back to off [the silently-unmonitored regression U4 exists to kill], (b) re-gate the
# role on the RAW observability_enabled so default-on hard-fails every unconfigured
# adopter, or (c) drop the unconfigured-skip warning.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
D="$ROOT/roles/observability/defaults/main.yml"
T="$ROOT/roles/observability/tasks/main.yml"
fail() { echo "FAIL: $1"; exit 1; }

# (a) on by default
grep -qE '^observability_enabled:[[:space:]]+true' "$D" \
    || fail "observability_enabled must default to true (on by default)"

# the activation gate: enabled AND the push endpoint configured
grep -qE '^observability_active:.*observability_enabled.*grafana_cloud_prometheus_url' "$D" \
    || fail "observability_active must derive from observability_enabled AND grafana_cloud_prometheus_url"

# (b) tasks gate on observability_ACTIVE, and NO task gates on the raw enabled flag
# (raw-enabled gating would hard-fail unconfigured adopters at the assert).
grep -qF 'observability_active | bool' "$T" \
    || fail "tasks must gate on observability_active (graceful skip when unconfigured)"
grep -qE 'when:[[:space:]]*observability_enabled[[:space:]]*\|[[:space:]]*bool[[:space:]]*$' "$T" \
    && fail "no task may gate on the RAW observability_enabled (hard-fails unconfigured adopters) -- use observability_active"

# (c) the enabled-but-unconfigured WARNING task exists (gated on enabled AND not active)
grep -qF 'not (observability_active | bool)' "$T" \
    || fail "an enabled-but-unconfigured WARNING task must exist (gated on enabled AND not active)"

echo "ALL OBSERVABILITY ROLE LINT CHECKS PASSED"
