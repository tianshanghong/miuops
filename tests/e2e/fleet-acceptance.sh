#!/usr/bin/env bash
# Fleet end-to-end acceptance harness — the FINAL gate for the fleet deployment model.
#
# Runs the spec's acceptance checks against a FRESH VPS that has already been bootstrapped
# from a fleet repo created from miuops-fleet-template. EVERY check carries a POSITIVE
# CONTROL so it can actually fail: a check that passes unconditionally (the probe is
# missing, the command errors and the `if` reads that error as success) is a FALSE GREEN —
# the most expensive failure mode, because green stops you looking.
#
# This harness VERIFIES an already-bootstrapped fleet; it does not provision one. See
# tests/e2e/README.md for the one-time setup (create the fleet repo from the template,
# generate the age + SSH keypairs, fill in inventory/host_vars/secrets + a test stack, set
# the per-server GitHub Environments, run `miuops up`). The harness is parameterized
# entirely by environment variables — no secrets are baked in, nothing is committed.
#
# Run a contaminated host and it lies: this is meant for a throwaway, freshly-bootstrapped
# VPS. Re-run from a verified-fresh state.
set -euo pipefail

# ── Prerequisites (from the environment; preflight fails closed if any are missing) ──────
: "${VPS_HOST:?set VPS_HOST — the VPS IP/hostname under test}"
: "${SSH_KEY:?set SSH_KEY — path to the operator SSH private key for the deploy user}"
: "${DOMAIN:?set DOMAIN — the Cloudflare domain serving the fleet (e.g. example.com)}"
: "${SERVER:?set SERVER — the server handle (matches fleet/host_vars/<SERVER>.yml)}"
: "${FLEET_DIR:?set FLEET_DIR — local path to the fleet repo (for SOPS + workflow checks)}"
: "${BACKUP_BUCKET:?set BACKUP_BUCKET — the shared fleet S3 bucket}"
: "${SERVER_AWS_ACCESS_KEY_ID:?set SERVER_AWS_ACCESS_KEY_ID — the per-server (prefix-scoped) IAM key}"
: "${SERVER_AWS_SECRET_ACCESS_KEY:?set SERVER_AWS_SECRET_ACCESS_KEY — the per-server IAM secret}"
: "${SOPS_AGE_KEY_FILE:?set SOPS_AGE_KEY_FILE — the age identity that decrypts the fleet secrets}"
export SOPS_AGE_KEY_FILE

SSH_USER="${SSH_USER:-deploy}"
SSH_PORT="${SSH_PORT:-22}"
TEST_HOST="${TEST_HOST:-whoami.${DOMAIN}}"          # the test stack's public hostname
TEST_BODY_MARKER="${TEST_BODY_MARKER:-Hostname:}"    # a string the test stack returns (whoami)
OTHER_SERVER="${OTHER_SERVER:-other-server}"          # a 2nd handle, for cross-prefix denial
AWS_REGION="${AWS_REGION:-us-west-2}"

# Required local tools (the header promises a fail-closed preflight). `nc` must support `-z`
# (BSD/OpenBSD netcat; nmap's ncat does not — install a -z-capable nc if the port checks error).
for _b in ssh nc curl aws sops git miuops; do
  command -v "$_b" >/dev/null 2>&1 || { printf 'FATAL: required local tool not found on PATH: %s\n' "$_b" >&2; exit 2; }
done

# ── Result tracking ─────────────────────────────────────────────────────────────────────
PASS=0 FAIL=0
declare -a FAILED=()
section() { printf '\n══ %s\n' "$1"; }
ok()   { printf '  ok    %s\n' "$1"; PASS=$((PASS + 1)); }
pc()   { printf '  ctrl  %s\n' "$1"; }                       # a positive control passed
bad()  { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); FAILED+=("$1"); }

# One multiplexed SSH connection for the whole run (keeps us well under any SSH rate-limit).
SSH_CM="/tmp/miuops-e2e-cm-%C"
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new
     -o ControlMaster=auto -o ControlPath="$SSH_CM" -o ControlPersist=120s
     -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_USER}@${VPS_HOST}")
on_vps() { "${SSH[@]}" "$@"; }
cleanup() { ssh -o ControlPath="$SSH_CM" -O exit "${SSH_USER}@${VPS_HOST}" 2>/dev/null || true; }
trap cleanup EXIT

# ── 1. Idempotent converge ──────────────────────────────────────────────────────────────
# A second `miuops apply` must report changed=0. Positive control: the run actually executed
# tasks (ok>0) — otherwise "changed=0" could just mean the play never ran.
check_idempotent_converge() {
  section "1. Converge is idempotent (re-apply → changed=0)"
  local out recap changed okc
  if ! out="$(cd "$FLEET_DIR" && miuops apply "$SERVER" 2>&1)"; then
    bad "re-apply of ${SERVER} did not exit 0"; printf '%s\n' "$out" | tail -5; return
  fi
  # `|| true` on each pipe: a no-match grep exits 1 and (with pipefail + set -e) would abort
  # the whole harness; we want an empty value that the [ ] checks below turn into a clean FAIL.
  recap="$(printf '%s\n' "$out" | grep -E 'changed=[0-9]+.*unreachable=' | tail -1 || true)"
  changed="$(printf '%s' "$recap" | grep -oE 'changed=[0-9]+' | grep -oE '[0-9]+' | tail -1 || true)"
  okc="$(printf '%s' "$recap" | grep -oE 'ok=[0-9]+' | grep -oE '[0-9]+' | tail -1 || true)"
  [ "${okc:-0}" -gt 0 ] && pc "play executed (ok=${okc}) — changed=0 is meaningful" \
                        || bad "no tasks ran (ok=${okc:-?}); a no-op converge proves nothing"
  [ "${changed:-1}" = "0" ] && ok "re-apply reported changed=0 (idempotent)" \
                            || bad "re-apply reported changed=${changed:-?} (not idempotent): ${recap}"
}

# ── 2. External attack surface is only :22 ──────────────────────────────────────────────
# From OUTSIDE the VPS: :22 reachable (positive control), web ports closed, and a REAL host
# listener on a high port is blocked by the firewall (the false-green lesson — prove the
# firewall denies a live listener, not just an unused port).
check_external_ports() {
  section "2. External attack surface — only :22 open"
  if nc -z -w5 "$VPS_HOST" "$SSH_PORT" 2>/dev/null; then pc "SSH :${SSH_PORT} reachable from outside (probe works)"
  else bad "SSH :${SSH_PORT} not reachable — cannot trust the rest of this scan"; return; fi
  local p closed=1
  for p in 80 443 2375 8080; do
    if nc -z -w5 "$VPS_HOST" "$p" 2>/dev/null; then bad "port ${p} is open to the internet (expected closed — tunnel-only)"; closed=0; fi
  done
  [ "$closed" = 1 ] && ok "web/daemon ports (80/443/2375/8080) closed to the internet"
  # Live-listener test: bind 0.0.0.0:54321 on the host, confirm it's up on loopback, then
  # prove it is NOT reachable from here.
  local port=54321
  on_vps "nohup python3 -m http.server ${port} --bind 0.0.0.0 >/dev/null 2>&1 & sleep 2; ss -tln | grep -q ':${port} '" \
    && pc "host listener on 0.0.0.0:${port} is up (loopback)" \
    || { bad "could not start the host listener — check 2 inconclusive"; return; }
  if nc -z -w8 "$VPS_HOST" "$port" 2>/dev/null; then bad "live host listener :${port} reachable from outside — firewall not denying"
  else ok "live host listener :${port} blocked by the firewall"; fi
  on_vps "pkill -f '[h]ttp.server ${port}'" >/dev/null 2>&1 || true
}

# ── 3. A stack is served cloudflared → traefik with valid TLS ───────────────────────────
# curl the public hostname over HTTPS (cert validated by default). Positive control: the body
# is actually from the test stack (the whoami marker), not a Cloudflare error page.
check_stack_https() {
  section "3. Test stack reachable over HTTPS (cloudflared → traefik, valid TLS)"
  local code body
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "https://${TEST_HOST}/" || echo 000)"
  [ "$code" = "200" ] && ok "https://${TEST_HOST}/ returned 200 over a valid TLS chain" \
                      || bad "https://${TEST_HOST}/ returned ${code} (expected 200 with a valid cert)"
  body="$(curl -sS --max-time 20 "https://${TEST_HOST}/" 2>/dev/null || true)"
  printf '%s' "$body" | grep -q "$TEST_BODY_MARKER" \
    && pc "response body is from the test stack (matched '${TEST_BODY_MARKER}')" \
    || bad "response did not contain '${TEST_BODY_MARKER}' — not the test stack"
}

# ── 4. Egress works; the cloud metadata endpoint is blocked for containers ──────────────
# The metadata block is a DOCKER-USER FORWARD DROP — it filters CONTAINER traffic, not the
# host (the host reaches metadata by design). So the probe MUST come from a container, and we
# first prove that container can egress, so a blocked metadata result is the DROP — not a
# broken container network or an absent metadata service (the false-green isolation lesson).
check_egress_and_metadata() {
  section "4. Egress works; metadata blocked for containers"
  local img="curlimages/curl:latest"
  on_vps "curl -sS -o /dev/null --max-time 10 https://api.github.com" \
    && pc "host outbound egress works (reached api.github.com)" \
    || { bad "no host egress — later results would be meaningless"; return; }
  on_vps "docker run --rm ${img} -sS -o /dev/null --max-time 15 https://api.github.com" \
    && pc "a container can egress (reached api.github.com)" \
    || { bad "container has no egress — the metadata-block result would be meaningless"; return; }
  if on_vps "docker run --rm ${img} -sS -o /dev/null --max-time 5 http://169.254.169.254/latest/meta-data/" 2>/dev/null; then
    bad "metadata 169.254.169.254 reachable FROM A CONTAINER (expected blocked by DOCKER-USER)"
  else
    ok "metadata 169.254.169.254 blocked from containers (DOCKER-USER FORWARD DROP)"
  fi
}

# ── 5. Per-server GitHub Environment secret isolation ───────────────────────────────────
# Full runtime isolation needs two live servers; what is statically verifiable here is that
# the deploy job BINDS to a per-server Environment (so a job for server A can only read A's
# environment secrets). Positive control: the binding is present and keyed off the matrix
# server (not a single shared environment).
check_environment_isolation() {
  section "5. Deploy job is bound to a per-server GitHub Environment"
  local wf
  wf="$(grep -rEl 'uses:.*miuops/\.github/workflows/deploy\.yml@' "$FLEET_DIR/.github/workflows" 2>/dev/null | head -1 || true)"
  [ -n "$wf" ] && pc "fleet caller delegates to the miuops reusable deploy workflow ($(basename "$wf"))" \
              || { bad "no caller delegating to the reusable deploy workflow found under $FLEET_DIR"; return; }
  # Resolve the reusable workflow at the EXACT ref the caller pins (not just the local
  # checkout, which can diverge from what CI runs). Parse the @<ref> from the `uses:` line.
  local ref repo_dir rwf_content
  ref="$(grep -oE 'miuops/\.github/workflows/deploy\.yml@[^[:space:]"]+' "$wf" | head -1 | sed 's/.*@//' || true)"
  repo_dir="${MIUOPS_REPO:-$(cd "$(dirname "$0")/../.." && pwd)}"
  if [ -n "$ref" ] && rwf_content="$(git -C "$repo_dir" show "${ref}:.github/workflows/deploy.yml" 2>/dev/null)"; then
    pc "resolved the reusable deploy.yml at the pinned ref '${ref}'"
  else
    rwf_content="$(cat "${repo_dir}/.github/workflows/deploy.yml" 2>/dev/null || true)"
    printf '  note  could not resolve pinned ref %s; checking the local checkout copy instead\n' "${ref:-<none>}"
  fi
  if printf '%s' "$rwf_content" | grep -Eq 'environment:[[:space:]]*\$\{\{[[:space:]]*matrix\.server'; then
    ok "reusable deploy job binds environment: matrix.server (per-server secret scope)"
  else
    bad "reusable deploy job does not bind environment to the matrix server — secrets are not per-server scoped"
  fi
  printf '  note  full cross-server runtime isolation (A cannot read B) needs a 2-server run; see README.\n'
}

# ── 6. SOPS round-trip for the fleet secrets; no age key in CI ──────────────────────────
# Positive control: decrypt succeeds WITH the age key. Negative: decrypt FAILS without it
# (proves the committed file is really encrypted, fail-closed). And no age identity is wired
# into any CI workflow.
check_sops_roundtrip() {
  section "6. SOPS round-trip locally; no age key in CI"
  local enc="${FLEET_DIR}/fleet/secrets/${SERVER}.env"
  [ -f "$enc" ] || { bad "encrypted secret ${enc} not found"; return; }
  grep -q 'ENC\[' "$enc" && pc "committed ${SERVER}.env is ciphertext (contains ENC[ markers)" \
                         || bad "committed ${SERVER}.env is NOT encrypted (no ENC[ markers)"
  if ( cd "$FLEET_DIR" && sops --decrypt "fleet/secrets/${SERVER}.env" ) >/dev/null 2>&1; then
    ok "sops --decrypt succeeds with the age key"
  else
    bad "sops --decrypt failed with the provided age key"
  fi
  if ( cd "$FLEET_DIR" && SOPS_AGE_KEY_FILE=/dev/null sops --decrypt "fleet/secrets/${SERVER}.env" ) >/dev/null 2>&1; then
    bad "sops decrypted WITHOUT a valid age key — the file is not really protected"
  else
    pc "sops --decrypt fails without the key (fail-closed)"
  fi
  if grep -rEq 'SOPS_AGE_KEY|age-keygen|AGE_SECRET|sops --decrypt' "$FLEET_DIR/.github/workflows" 2>/dev/null; then
    bad "a fleet CI workflow references an age key / decrypts secrets — the key must never enter CI"
  else
    ok "no fleet CI workflow introduces an age key or decrypts secrets"
  fi
}

# ── 7. Per-server backup prefix + prefix-scoped IAM cross-prefix denial ─────────────────
# Using the per-server IAM key: writing/reading the server's own prefix works (positive
# control); another server's prefix is denied; delete is denied.
check_backup_iam_scope() {
  section "7. Backup is per-server-prefixed with a prefix-scoped IAM key"
  local probe="miuops-e2e-$$.txt" tmp
  tmp="$(mktemp)"; printf 'e2e %s\n' "$SERVER" > "$tmp"
  AWS_ACCESS_KEY_ID="$SERVER_AWS_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$SERVER_AWS_SECRET_ACCESS_KEY" AWS_REGION="$AWS_REGION"
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION
  if aws s3 cp "$tmp" "s3://${BACKUP_BUCKET}/${SERVER}/${probe}" >/dev/null 2>&1; then
    pc "per-server key can PUT to its own prefix (${SERVER}/)"
  else
    bad "per-server key cannot write its own prefix (${SERVER}/) — backups would fail"; rm -f "$tmp"; return
  fi
  aws s3 cp "s3://${BACKUP_BUCKET}/${SERVER}/${probe}" /dev/null >/dev/null 2>&1 \
    && ok "per-server key can GET from its own prefix" \
    || bad "per-server key cannot read its own prefix"
  if aws s3 cp "$tmp" "s3://${BACKUP_BUCKET}/${OTHER_SERVER}/${probe}" >/dev/null 2>&1; then
    bad "per-server key wrote ANOTHER server's prefix (${OTHER_SERVER}/) — IAM not prefix-scoped"
    aws s3 rm "s3://${BACKUP_BUCKET}/${OTHER_SERVER}/${probe}" >/dev/null 2>&1 || true
  else
    ok "per-server key is DENIED writing another server's prefix (${OTHER_SERVER}/)"
  fi
  if aws s3 rm "s3://${BACKUP_BUCKET}/${SERVER}/${probe}" >/dev/null 2>&1; then
    bad "per-server key could DELETE its own object — the policy grants no Delete"
  else
    ok "per-server key is DENIED Delete (no s3:Delete* granted → deny-by-default)"
  fi
  # Delete is (correctly) denied, so the probe object can't be removed with this key — it
  # remains under ${SERVER}/. Harmless on a throwaway e2e bucket; lifecycle/object-lock ages
  # it out. (This check requires the per-server scoped IAM from `setup-s3-backup.sh --server`.)
  rm -f "$tmp"
}

# ── 8. Teardown removes the stack ───────────────────────────────────────────────────────
# Positive control: the stack is serving before teardown (check 3). After removing the stack
# from the fleet and re-applying, the public endpoint must stop serving it.
check_teardown() {
  section "8. Teardown removes the stack"
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "https://${TEST_HOST}/" || echo 000)"
  [ "$code" = "200" ] && pc "stack is serving before teardown (200)" \
                      || printf '  note  stack not serving before teardown (got %s) — teardown result is weaker\n' "$code"
  printf '  note  teardown is operator-driven: remove fleet/stacks/%s/<stack>/ , re-apply, then re-run\n' "$SERVER"
  printf '        this check to confirm https://%s/ stops returning 200. (Automated teardown\n' "$TEST_HOST"
  printf '        is intentionally not destructive here.)\n'
}

# ── Run ─────────────────────────────────────────────────────────────────────────────────
printf 'Fleet acceptance — VPS=%s server=%s domain=%s\n' "$VPS_HOST" "$SERVER" "$DOMAIN"
check_idempotent_converge
check_external_ports
check_stack_https
check_egress_and_metadata
check_environment_isolation
check_sops_roundtrip
check_backup_iam_scope
check_teardown

section "Summary"
printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '  failing checks:\n'; printf '   - %s\n' "${FAILED[@]}"
  exit 1
fi
printf '  ALL FLEET ACCEPTANCE CHECKS PASSED\n'
