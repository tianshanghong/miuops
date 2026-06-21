#!/usr/bin/env bash
# Unit tests for the miuops CLI. Sources the CLI with --source-only (no dispatch)
# into a sandboxed SCRIPT_DIR so config-writing helpers can be exercised offline.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

export MIUOPS_TEST_SCRIPT_DIR="$TMP"
# shellcheck disable=SC1090
source "$ROOT/miuops" --source-only

# --- helpers: write_host_vars / hv_tunnel / hv_domains ---
mkdir -p "$TMP/host_vars"
write_host_vars server-a tunnelA example.com example.org
[ -f "$TMP/host_vars/server-a.yml" ] || fail "host_vars not written"
hv_tunnel server-a | grep -qx tunnelA      || fail "tunnel_id wrong"
hv_domains server-a | grep -qx example.com || fail "domain example.com missing"
hv_domains server-a | grep -qx example.org || fail "domain example.org missing"
# regression: hv_domains must NOT return the YAML '---' separator as a domain
[ "$(hv_domains server-a | wc -l | tr -d ' ')" = "2" ] || fail "hv_domains returned != 2 domains (phantom --?)"
hv_domains server-a | grep -qx -- '--' && fail "hv_domains leaked the '---' separator"

# --- inventory_upsert is additive (does not clobber other hosts) ---
inventory_upsert server-a 198.51.100.1 root
inventory_upsert server-b 198.51.100.2 root
grep -qE '^server-a ' "$TMP/inventory.ini" || fail "server-a missing from inventory"
grep -qE '^server-b ' "$TMP/inventory.ini" || fail "server-b missing from inventory"
inventory_upsert server-a 198.51.100.9 admin   # update in place
[ "$(grep -c '^server-a ' "$TMP/inventory.ini")" = "1" ] || fail "server-a duplicated"
grep -q 'ansible_host=198.51.100.9' "$TMP/inventory.ini" || fail "server-a not updated"

# --- domain_owner finds the owning host ---
[ "$(domain_owner example.com)" = "server-a" ] || fail "domain_owner wrong"
[ -z "$(domain_owner unowned.example)" ]        || fail "domain_owner false positive"

# --- validation helpers ---
valid_host_alias 'good-host_1.example' || fail "valid host alias rejected"
valid_host_alias 'bad|host'   && fail "host alias with | accepted"
valid_host_alias '../etc/x'   && fail "host alias with / accepted (path traversal)"
valid_domain 'example.com'    || fail "valid domain rejected"
valid_domain 'not a domain'   && fail "invalid domain accepted"

# --- write_host_vars with zero domains must not emit a '- ""' entry ---
write_host_vars solo tdx
grep -q -- '- ""' "$TMP/host_vars/solo.yml" && fail "empty domain entry written"
[ -z "$(hv_domains solo)" ] || fail "solo host should have no domains"

# --- cf_zone_id parses the Cloudflare response (curl mocked, no network) ---
got="$( export CF_API_TOKEN=x; curl() { printf '{"result":[{"id":"ZONEID123"}],"success":true}\n200\n'; }; cf_zone_id example.com )"
[ "$got" = "ZONEID123" ] || fail "cf_zone_id did not parse zone id (got: '$got')"

# --- Task 7: cmd_up uses host_vars, never group_vars ---
grep -q 'group_vars' "$ROOT/miuops" && fail "miuops still references group_vars"
grep -q 'write_host_vars "\$ssh_host"' "$ROOT/miuops" || fail "up does not call write_host_vars"

# --- Task 8: apply targets --limit; --no-apply skips converge ---
out="$(cd "$ROOT" && ./miuops apply --dry-run server-a 2>&1 || true)"
echo "$out" | grep -q -- "--limit server-a" || fail "apply --dry-run should show --limit server-a"
out="$(cd "$ROOT" && ./miuops apply --no-apply server-a 2>&1 || true)"
echo "$out" | grep -qi "no-apply" || fail "--no-apply should skip converge"

# --- Task 9: add-domain / remove-domain reject unknown hosts (offline) ---
out="$(cd "$ROOT" && CF_API_TOKEN=x ./miuops add-domain nope new.example 2>&1 || true)"
echo "$out" | grep -qiE 'no host_vars|inventory' || fail "add-domain should reject unknown host"
out="$(cd "$ROOT" && CF_API_TOKEN=x ./miuops remove-domain nope x.example 2>&1 || true)"
echo "$out" | grep -qiE 'no host_vars' || fail "remove-domain should reject unknown host"
out="$(cd "$ROOT" && CF_API_TOKEN=x ./miuops add-domain onlyhost 2>&1 || true)"
echo "$out" | grep -qi 'Usage' || fail "add-domain with no domains should show usage"

echo "ALL CLI HELPER TESTS PASSED"
