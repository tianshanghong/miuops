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
# host_vars must be written 0600 (portable: Linux `stat -c`, macOS `stat -f`)
hvperm="$(stat -c '%a' "$TMP/host_vars/server-a.yml" 2>/dev/null || stat -f '%Lp' "$TMP/host_vars/server-a.yml")"
[ "$hvperm" = "600" ] || fail "host_vars not written 0600 (got $hvperm)"
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
valid_host_alias "$(printf 'good\nrm -rf /')"   && fail "host alias with embedded newline accepted"
valid_domain "$(printf 'a.com\nevil;payload')"  && fail "domain with embedded newline accepted"

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

# --- review-fix regressions ---

# lc: lowercase normalization (DNS is case-insensitive)
[ "$(lc Example.COM)" = "example.com" ] || fail "lc did not lowercase"

# domain_owner uses fixed-string match — a '.' must not act as a regex wildcard
write_host_vars rgxhost trx abcdXcom
[ -z "$(domain_owner abcd.com)" ] || fail "domain_owner matched via regex '.' (need grep -F)"

# inventory_upsert matches the host as an exact field (dot is not a wildcard)
inventory_upsert host.a 203.0.113.1 root
inventory_upsert hostXa 203.0.113.2 root
inventory_upsert host.a 203.0.113.9 root   # update host.a only
grep -Fq 'hostXa ansible_host=203.0.113.2 ' "$TMP/inventory.ini" || fail "hostXa clobbered by host.a (dot wildcard)"
grep -Fq 'host.a ansible_host=203.0.113.9 ' "$TMP/inventory.ini" || fail "host.a not updated"

# remove-domain refuses the last domain BEFORE deleting DNS (no token needed)
write_host_vars onehost ot only.example
out="$(cd "$ROOT" && MIUOPS_TEST_SCRIPT_DIR="$TMP" ./miuops remove-domain onehost only.example 2>&1 || true)"
echo "$out" | grep -qi 'Refusing to remove the last domain' || fail "remove-domain must refuse last domain before deleting"

# apply ensures Galaxy collections (visible in dry-run)
out="$(cd "$ROOT" && ./miuops apply --dry-run server-a 2>&1 || true)"
echo "$out" | grep -qi 'Galaxy requirements' || fail "apply should ensure Galaxy collections"

# cf_delete_cname skips a CNAME pointing elsewhere (not our tunnel)
out="$( export CF_API_TOKEN=x; curl() { printf '{"success":true,"result":[{"id":"R1","content":"other.example.com"}]}'; }; cf_delete_cname z1 app.example.com TUN1 2>&1 )"
echo "$out" | grep -qi 'not this tunnel' || fail "cf_delete_cname should skip a non-tunnel CNAME"

# cf_delete_cname deletes a CNAME pointing to our tunnel (and checks .success)
out="$( export CF_API_TOKEN=x; curl() { if printf '%s' "$*" | grep -q DELETE; then printf '{"success":true}'; else printf '{"success":true,"result":[{"id":"R1","content":"TUN1.cfargotunnel.com"}]}'; fi; }; cf_delete_cname z1 app.example.com TUN1 2>&1 )"
echo "$out" | grep -qi 'Deleted CNAME' || fail "cf_delete_cname should delete a matching CNAME"

# cf_create_cname: existing record pointing elsewhere -> hard error (not silent OK)
out="$( ( export CF_API_TOKEN=x; curl() { if printf '%s' "$*" | grep -q POST; then printf '{"success":false,"errors":[{"message":"A record with that host already exists."}]}'; else printf '{"success":true,"result":[{"id":"R1","content":"other.example.com"}]}'; fi; }; cf_create_cname z1 app.example.com TUN1 ) 2>&1 || true )"
echo "$out" | grep -qi 'not this tunnel' || fail "cf_create_cname must reject an existing CNAME pointing elsewhere"

# cf_create_cname: existing record pointing at our tunnel -> OK
out="$( ( export CF_API_TOKEN=x; curl() { if printf '%s' "$*" | grep -q POST; then printf '{"success":false,"errors":[{"message":"record already exists"}]}'; else printf '{"success":true,"result":[{"id":"R1","content":"TUN1.cfargotunnel.com"}]}'; fi; }; cf_create_cname z1 app.example.com TUN1 ) 2>&1 || true )"
echo "$out" | grep -qi 'already points here' || fail "cf_create_cname should accept an existing CNAME that points here"

# cf_create_cname: a non-already-exists API failure -> hard error
out="$( ( export CF_API_TOKEN=x; curl() { printf '{"success":false,"errors":[{"message":"Invalid zone"}]}'; }; cf_create_cname z1 app.example.com TUN1 ) 2>&1 || true )"
echo "$out" | grep -qi 'Failed to create' || fail "cf_create_cname must die on an API failure"

# cf_zone_id walks up to the parent zone for a subdomain (dev.example.com -> example.com)
out="$( export CF_API_TOKEN=x; curl() { if printf '%s' "$*" | grep -q 'name=dev.example.com'; then printf '{"success":true,"result":[]}\n200'; elif printf '%s' "$*" | grep -q 'name=example.com'; then printf '{"success":true,"result":[{"id":"ZONE1"}]}\n200'; else printf '{"success":true,"result":[]}\n200'; fi; }; cf_zone_id dev.example.com )"
echo "$out" | grep -qx ZONE1 || fail "cf_zone_id should resolve a subdomain to its parent zone"

# cf_zone_id resolves an apex directly (regression)
out="$( export CF_API_TOKEN=x; curl() { printf '{"success":true,"result":[{"id":"ZONE2"}]}\n200'; }; cf_zone_id example.com )"
echo "$out" | grep -qx ZONE2 || fail "cf_zone_id should resolve an apex domain directly"

# cf_zone_id dies when neither the name nor any parent is a zone
out="$( ( export CF_API_TOKEN=x; curl() { printf '{"success":true,"result":[]}\n200'; }; cf_zone_id sub.unknown.example ) 2>&1 || true )"
echo "$out" | grep -qi 'Zone not found' || fail "cf_zone_id must die when no parent zone matches"

# cf_delete_cname: a failed delete -> hard error (not a warning)
out="$( ( export CF_API_TOKEN=x; curl() { if printf '%s' "$*" | grep -q DELETE; then printf '{"success":false,"errors":[{"message":"boom"}]}'; else printf '{"success":true,"result":[{"id":"R1","content":"TUN1.cfargotunnel.com"}]}'; fi; }; cf_delete_cname z1 app.example.com TUN1 ) 2>&1 || true )"
echo "$out" | grep -qi 'did not confirm deletion' || fail "cf_delete_cname must die on a failed delete"

# remove-domain: missing tunnel_id -> hard error
write_host_vars notunnel "" a.example b.example
out="$(cd "$ROOT" && MIUOPS_TEST_SCRIPT_DIR="$TMP" ./miuops remove-domain notunnel a.example 2>&1 || true)"
echo "$out" | grep -qi 'no tunnel_id' || fail "remove-domain must require a non-empty tunnel_id"

echo "ALL CLI HELPER TESTS PASSED"
