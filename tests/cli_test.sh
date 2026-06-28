#!/usr/bin/env bash
# Unit tests for the miuops CLI. Sources the CLI with --source-only (no dispatch)
# into a sandboxed SCRIPT_DIR so config-writing helpers can be exercised offline.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

export MIUOPS_TEST_SCRIPT_DIR="$TMP/tool"   # tool assets (playbook / roles / ansible.cfg)
export MIUOPS_FLEET_DIR="$TMP/fleet"   # fleet config (inventory + host_vars) lives here
# shellcheck disable=SC1090
source "$ROOT/miuops" --source-only

# --- helpers: write_host_vars / hv_tunnel / hv_domains ---
mkdir -p "$TMP/fleet/host_vars"
write_host_vars server-a tunnelA example.com example.org
[ -f "$TMP/fleet/host_vars/server-a.yml" ] || fail "host_vars not written"
# discriminating: config must land in FLEET_DIR, NOT leak into SCRIPT_DIR (the move is the point)
[ ! -e "$TMP/tool/host_vars/server-a.yml" ] || fail "host_vars leaked into SCRIPT_DIR (path not moved to FLEET_DIR)"
# host_vars must be written 0600 (portable: Linux `stat -c`, macOS `stat -f`)
hvperm="$(stat -c '%a' "$TMP/fleet/host_vars/server-a.yml" 2>/dev/null || stat -f '%Lp' "$TMP/fleet/host_vars/server-a.yml")"
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
grep -qE '^server-a ' "$TMP/fleet/inventory.ini" || fail "server-a missing from inventory"
grep -qE '^server-b ' "$TMP/fleet/inventory.ini" || fail "server-b missing from inventory"
[ ! -e "$TMP/tool/inventory.ini" ] || fail "inventory leaked into SCRIPT_DIR (path not moved to FLEET_DIR)"
inventory_upsert server-a 198.51.100.9 admin   # update in place
[ "$(grep -c '^server-a ' "$TMP/fleet/inventory.ini")" = "1" ] || fail "server-a duplicated"
grep -q 'ansible_host=198.51.100.9' "$TMP/fleet/inventory.ini" || fail "server-a not updated"

# --- domain_owner finds the owning host ---
[ "$(domain_owner example.com)" = "server-a" ] || fail "domain_owner wrong"
[ -z "$(domain_owner unowned.example)" ]        || fail "domain_owner false positive"

# --- validation helpers ---
valid_host_alias 'good-host_1.example' || fail "valid host alias rejected"
valid_host_alias 'bad|host'   && fail "host alias with | accepted"
valid_host_alias '../etc/x'   && fail "host alias with / accepted (path traversal)"
valid_host_alias '-leading'   && fail "host alias with leading dash accepted (--name flag-swallow / flag-injection guard)"
valid_host_alias '..'         && fail "host alias '..' accepted"
valid_host_alias '.hidden'    && fail "host alias with leading dot accepted"
valid_domain 'example.com'    || fail "valid domain rejected"
valid_domain 'not a domain'   && fail "invalid domain accepted"
valid_host_alias "$(printf 'good\nrm -rf /')"   && fail "host alias with embedded newline accepted"
valid_domain "$(printf 'a.com\nevil;payload')"  && fail "domain with embedded newline accepted"

# --- write_host_vars with zero domains must not emit a '- ""' entry ---
write_host_vars solo tdx
grep -q -- '- ""' "$TMP/fleet/host_vars/solo.yml" && fail "empty domain entry written"
[ -z "$(hv_domains solo)" ] || fail "solo host should have no domains"

# --- cf_zone_id parses the Cloudflare response (curl mocked, no network) ---
got="$( export CF_API_TOKEN=x; curl() { printf '{"result":[{"id":"ZONEID123"}],"success":true}\n200\n'; }; cf_zone_id example.com )"
[ "$got" = "ZONEID123" ] || fail "cf_zone_id did not parse zone id (got: '$got')"

# --- Task 7: cmd_up writes per-host config to host_vars (verified above it lands under
# FLEET_DIR/host_vars, never SCRIPT_DIR), never group_vars. group_vars is now a fleet-WIDE
# config layer with its own read-only shadow guard (below), so we no longer forbid the
# word -- the per-host invariant is covered by write_host_vars landing in host_vars. ---
grep -qF 'write_host_vars "$handle"' "$ROOT/miuops" || fail "up does not call write_host_vars with the resolved handle"

# --- U8: up --name decouples the fleet handle (inventory key / host_vars / tunnel /
# domain owner) from the SSH target, so a server need not be keyed by its IP. ---
[ "$(up_resolve_handle myname 198.51.100.7)" = "myname" ]      || fail "up_resolve_handle must prefer --name"
[ "$(up_resolve_handle '' 198.51.100.7)" = "198.51.100.7" ]    || fail "up_resolve_handle must default to the ssh host"
# the handle drives the fleet identity; ssh_host stays the SSH target + ansible_host
grep -qF 'inventory_upsert "$handle" "$ssh_host"' "$ROOT/miuops" || fail "up must key inventory by handle, ansible_host by ssh_host"
grep -qF 'run_apply "$handle"' "$ROOT/miuops"                    || fail "up must converge the handle"
grep -qF 'tunnel_name="miuops-${handle' "$ROOT/miuops"          || fail "tunnel name must derive from the handle"
grep -qF '"${ssh_user}@${ssh_host}" true' "$ROOT/miuops"         || fail "the SSH reachability check must target ssh_host"
# pin EVERY decoupled site (a mutation re-keying any of these off the IP must fail here)
grep -qF '"$owner" != "$handle"' "$ROOT/miuops"                  || fail "domain-owner check must compare to the handle"
grep -qF 'hv_tunnel "$handle"' "$ROOT/miuops"                    || fail "tunnel reuse must look up the handle"
grep -qF 'hv_domains "$handle"' "$ROOT/miuops"                   || fail "domain merge must look up the handle"
grep -qF '"${SECRETS_DIR}/${handle}.env"' "$ROOT/miuops"         || fail "the app .env path must be keyed by the handle"
grep -qF 'sops_provision_env "$handle"' "$ROOT/miuops"           || fail "the app .env must be provisioned under the handle"

# --- Task 8: apply targets --limit; --no-apply skips converge ---
out="$(cd "$ROOT" && ./miuops apply --dry-run server-a 2>&1 || true)"
echo "$out" | grep -q -- "--limit server-a" || fail "apply --dry-run should show --limit server-a"
out="$(cd "$ROOT" && ./miuops apply --no-apply server-a 2>&1 || true)"
echo "$out" | grep -qi "no-apply" || fail "--no-apply should skip converge"

# --- apply with no fleet inventory dies with a clear, actionable error ---
out="$(cd "$ROOT" && MIUOPS_FLEET_DIR="$TMP/empty-fleet" ./miuops apply 2>&1 || true)"
echo "$out" | grep -qi 'No fleet inventory'                || fail "apply must die clearly when fleet inventory is missing"
echo "$out" | grep -qiE 'MIUOPS_FLEET_DIR|fleet repo root' || fail "missing-inventory error must be actionable"

# --- tool-checkout host_vars must NOT silently shadow the fleet's. Ansible loads
# playbook-adjacent (SCRIPT_DIR) host_vars at HIGHER precedence than inventory-adjacent
# (FLEET_DIR), so converge must fail closed when the tool checkout still holds host_vars. ---
mkdir -p "$TMP/tool/host_vars"; : > "$TMP/tool/host_vars/server-a.yml"
out="$(cd "$ROOT" && ./miuops apply server-a 2>&1 || true)"
echo "$out" | grep -qiE 'would load over|shadow|tool checkout has host_vars' \
    || fail "apply must refuse when tool-checkout host_vars could shadow the fleet"
rm -rf "$TMP/tool/host_vars"
# the same guard covers the non-.yml forms Ansible loads (.yaml here)
mkdir -p "$TMP/tool/host_vars"; : > "$TMP/tool/host_vars/server-a.yaml"
out="$(cd "$ROOT" && ./miuops apply server-a 2>&1 || true)"
echo "$out" | grep -qiE 'tool checkout has host_vars' || fail "host_vars guard missed the .yaml form"
rm -rf "$TMP/tool/host_vars"
# positive control: with NO shadowing host_vars, the guard does not fire and apply proceeds
out="$(cd "$ROOT" && ./miuops apply --dry-run server-a 2>&1 || true)"
echo "$out" | grep -qiE 'would load over|tool checkout has host_vars' && fail "shadow guard false-fired without tool host_vars"
echo "$out" | grep -q -- "--limit server-a" || fail "apply --dry-run should proceed when no shadow"

# --- tool-checkout group_vars must NOT silently shadow the fleet's either -- same
# precedence issue as host_vars (playbook-adjacent SCRIPT_DIR outranks the fleet's), so a
# fleet-wide group_vars/all left in the tool checkout would override the fleet's silently. ---
mkdir -p "$TMP/tool/group_vars"; : > "$TMP/tool/group_vars/all.yml"
out="$(cd "$ROOT" && ./miuops apply server-a 2>&1 || true)"
echo "$out" | grep -qiE 'would load over|shadow|tool checkout has group_vars' \
    || fail "apply must refuse when tool-checkout group_vars could shadow the fleet"
rm -rf "$TMP/tool/group_vars"
# positive control: with NO shadowing group_vars, the guard does not fire and apply proceeds
out="$(cd "$ROOT" && ./miuops apply --dry-run server-a 2>&1 || true)"
echo "$out" | grep -qiE 'tool checkout has group_vars' && fail "group_vars shadow guard false-fired without tool group_vars"
echo "$out" | grep -q -- "--limit server-a" || fail "apply --dry-run should proceed when no group_vars shadow"

# the guard must catch EVERY form Ansible loads (.yaml, extension-less, a directory),
# not only *.yml -- a leftover all.yaml in the tool checkout would otherwise silently
# override the fleet (one such file mis-converges every host).
for form in yaml noext dir caps; do
    rm -rf "$TMP/tool/group_vars"; mkdir -p "$TMP/tool/group_vars"
    case "$form" in
        yaml)  : > "$TMP/tool/group_vars/all.yaml" ;;
        noext) : > "$TMP/tool/group_vars/all" ;;
        dir)   mkdir -p "$TMP/tool/group_vars/all"; : > "$TMP/tool/group_vars/all/x.yml" ;;
        caps)  : > "$TMP/tool/group_vars/all.YML" ;;   # Ansible loads it case-insensitively
    esac
    out="$(cd "$ROOT" && ./miuops apply server-a 2>&1 || true)"
    echo "$out" | grep -qiE 'tool checkout has group_vars' || fail "group_vars guard missed the '$form' form (Ansible loads it)"
done
rm -rf "$TMP/tool/group_vars"
# but it must NOT false-fire on the shipped template or an editor backup (Ansible loads neither)
mkdir -p "$TMP/tool/group_vars"; : > "$TMP/tool/group_vars/all.yml.example"; : > "$TMP/tool/group_vars/all.yml.bak"
out="$(cd "$ROOT" && ./miuops apply --dry-run server-a 2>&1 || true)"
echo "$out" | grep -qiE 'tool checkout has group_vars' && fail "group_vars guard false-fired on .example/.bak"
echo "$out" | grep -q -- "--limit server-a" || fail "apply should proceed with only .example/.bak in group_vars"
rm -rf "$TMP/tool/group_vars"

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
grep -Fq 'hostXa ansible_host=203.0.113.2 ' "$TMP/fleet/inventory.ini" || fail "hostXa clobbered by host.a (dot wildcard)"
grep -Fq 'host.a ansible_host=203.0.113.9 ' "$TMP/fleet/inventory.ini" || fail "host.a not updated"

# remove-domain refuses the last domain BEFORE deleting DNS (no token needed)
write_host_vars onehost ot only.example
out="$(cd "$ROOT" && MIUOPS_TEST_SCRIPT_DIR="$TMP/tool" ./miuops remove-domain onehost only.example 2>&1 || true)"
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
out="$( export CF_API_TOKEN=x; curl() { if printf '%s' "$*" | grep -q 'name=dev.example.com'; then printf '{"success":true,"result":[]}\n200'; elif printf '%s' "$*" | grep -q 'name=example.com'; then printf '{"success":true,"result":[{"id":"ZONE1","name":"example.com"}]}\n200'; else printf '{"success":true,"result":[]}\n200'; fi; }; cf_zone_id dev.example.com 2>/dev/null )"
echo "$out" | grep -qx ZONE1 || fail "cf_zone_id should resolve a subdomain to its parent zone"

# cf_zone_id resolves an apex directly (regression)
out="$( export CF_API_TOKEN=x; curl() { printf '{"success":true,"result":[{"id":"ZONE2"}]}\n200'; }; cf_zone_id example.com )"
echo "$out" | grep -qx ZONE2 || fail "cf_zone_id should resolve an apex domain directly"

# cf_zone_id dies when neither the name nor any parent is a zone
out="$( ( export CF_API_TOKEN=x; curl() { printf '{"success":true,"result":[]}\n200'; }; cf_zone_id sub.unknown.example ) 2>&1 || true )"
echo "$out" | grep -qi 'Zone not found' || fail "cf_zone_id must die when no parent zone matches"

# cf_zone_id surfaces the matched parent zone name on walk-up (stderr, not stdout)
err="$( export CF_API_TOKEN=x; curl() { if printf '%s' "$*" | grep -q 'name=dev.example.com'; then printf '{"success":true,"result":[]}\n200'; else printf '{"success":true,"result":[{"id":"ZONE1","name":"example.com"}]}\n200'; fi; }; cf_zone_id dev.example.com 2>&1 >/dev/null )"
echo "$err" | grep -qi "parent zone 'example.com'" || fail "cf_zone_id should surface the parent zone name on walk-up"

# acm_wildcard_note warns for a subdomain's 2nd-level wildcard, not for an apex
out="$( acm_wildcard_note dev.example.com 2>&1 )"
echo "$out" | grep -qi 'Advanced Certificate Manager' || fail "acm_wildcard_note should warn for a subdomain"
out="$( acm_wildcard_note example.com 2>&1 )"
[[ -z "$out" ]] || fail "acm_wildcard_note should not warn for an apex domain"

# cf_delete_cname: a failed delete -> hard error (not a warning)
out="$( ( export CF_API_TOKEN=x; curl() { if printf '%s' "$*" | grep -q DELETE; then printf '{"success":false,"errors":[{"message":"boom"}]}'; else printf '{"success":true,"result":[{"id":"R1","content":"TUN1.cfargotunnel.com"}]}'; fi; }; cf_delete_cname z1 app.example.com TUN1 ) 2>&1 || true )"
echo "$out" | grep -qi 'did not confirm deletion' || fail "cf_delete_cname must die on a failed delete"

# remove-domain: missing tunnel_id -> hard error
write_host_vars notunnel "" a.example b.example
out="$(cd "$ROOT" && MIUOPS_TEST_SCRIPT_DIR="$TMP/tool" ./miuops remove-domain notunnel a.example 2>&1 || true)"
echo "$out" | grep -qi 'no tunnel_id' || fail "remove-domain must require a non-empty tunnel_id"

# --- U4: observability on by default + graceful skip + an `up` nudge ---
# default-on: the obs role is enabled unless a host opts out (no more silently-off).
grep -qE '^observability_enabled:[[:space:]]+true' "$ROOT/roles/observability/defaults/main.yml" \
    || fail "observability_enabled must default to true (obs on by default)"

# obs_configured <handle>: true iff the Grafana push endpoint is set for this host --
# in group_vars/all.yml (its blessed home) OR the host's host_vars. A COMMENTED key
# must NOT count (the operator who left a stub is exactly who the nudge is for).
mkdir -p "$TMP/fleet/group_vars" "$TMP/fleet/host_vars"
: > "$TMP/fleet/group_vars/all.yml"
obs_configured srv && fail "obs_configured must be false when nothing sets the endpoint"
echo '# grafana_cloud_prometheus_url: "https://x"' > "$TMP/fleet/group_vars/all.yml"
obs_configured srv && fail "obs_configured must be false for a COMMENTED endpoint (#2)"
printf 'grafana_cloud_prometheus_url: ""\n' > "$TMP/fleet/group_vars/all.yml"
obs_configured srv && fail "obs_configured must be false for an EMPTY-valued stub"
echo 'grafana_cloud_prometheus_url: "https://x/api/prom/push"' > "$TMP/fleet/group_vars/all.yml"
obs_configured srv || fail "obs_configured must be true when group_vars/all sets the endpoint"
: > "$TMP/fleet/group_vars/all.yml"
echo 'grafana_cloud_prometheus_url: "https://x"' > "$TMP/fleet/host_vars/srv.yml"
obs_configured srv || fail "obs_configured must be true when the host's host_vars sets the endpoint (#3)"
rm -f "$TMP/fleet/host_vars/srv.yml"

# obs_opted_out <handle>: true iff observability_enabled is a YAML false, in host_vars
# OR group_vars, tolerant of spacing/quoting/case (#4).
: > "$TMP/fleet/group_vars/all.yml"
obs_opted_out srv && fail "obs_opted_out must be false when nothing disables obs"
for spelling in 'observability_enabled: false' 'observability_enabled : false' \
                'observability_enabled: "false"' 'observability_enabled: False' \
                'observability_enabled: no'; do
    printf '%s\n' "$spelling" > "$TMP/fleet/host_vars/srv.yml"
    obs_opted_out srv || fail "obs_opted_out must catch host_vars opt-out spelling: [$spelling]"
done
rm -f "$TMP/fleet/host_vars/srv.yml"
# A non-false value must NOT count as opt-out (the false|no|off alternation must not
# prefix-match nope/offline/true -- else obs would silently never run).
for nonfalse in 'observability_enabled: true' 'observability_enabled: nope' \
                'observability_enabled: offline' 'observability_enabled: notyet'; do
    printf '%s\n' "$nonfalse" > "$TMP/fleet/host_vars/srv.yml"
    obs_opted_out srv && fail "obs_opted_out must NOT fire on a non-false value: [$nonfalse]"
done
rm -f "$TMP/fleet/host_vars/srv.yml"
printf 'observability_enabled: false\n' > "$TMP/fleet/group_vars/all.yml"
obs_opted_out srv || fail "obs_opted_out must catch a group_vars opt-out (#4)"
rm -rf "$TMP/fleet/group_vars" "$TMP/fleet/host_vars"

# `up` nudges via obs_configured + the robust obs_opted_out.
grep -qF 'obs_configured' "$ROOT/miuops" || fail "up must use obs_configured to nudge"
grep -qF 'obs_opted_out'  "$ROOT/miuops" || fail "up must use obs_opted_out (robust opt-out check)"

echo "ALL CLI HELPER TESTS PASSED"
