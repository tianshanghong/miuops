#!/usr/bin/env bash
# Empirically exercise the REMOTE half of deploy-server.sh -- the `<<'REMOTE'`
# heredoc that runs on the host over SSH -- which the other offline tests can't
# reach. We extract that body verbatim, run it with a stubbed `docker` against
# fake stack dirs, and assert the ACTUAL compose commands it issues for each
# (FORCE_RECREATE, ONLY_STACK) combination. No SSH, no real docker, no imagined
# output: every assertion reads what the code actually did (a recorded log / rc).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DS="$ROOT/.github/scripts/deploy-server.sh"
fail() { echo "FAIL: $1"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Extract the remote heredoc body verbatim (between the `<<'REMOTE'` opener and
# the column-0 `REMOTE` terminator) -- this is exactly what ssh feeds to bash.
BODY="$TMP/remote-body.sh"
awk "/<<'REMOTE'/{f=1;next} /^REMOTE\$/{f=0} f" "$DS" > "$BODY"
[ -s "$BODY" ] || fail "could not extract the remote heredoc body from deploy-server.sh"

# Stubbed docker on PATH: records `compose up` invocations, satisfies `config -q`
# and `ls`, so the body runs end-to-end without a daemon.
bin="$TMP/bin"; mkdir -p "$bin"
cat > "$bin/docker" <<STUB
#!/usr/bin/env bash
[ "\$1" = compose ] || exit 0
shift
for a in "\$@"; do
  case "\$a" in
    config) [ "\$(basename "\$PWD")" = broken ] && exit 2
      [ -f "\$PWD/docker-compose.yml" ] || exit 2
      if [[ "\$*" == *'--format json'* ]]; then cat "\$PWD/resolved.json"; fi
      exit 0 ;;  # 'broken' = invalid compose
    up)     printf 'UP %s %s\n' "\$(basename "\$PWD")" "\$*" >> "\$STUB_LOG"; exit 0 ;;  # stack = cwd basename
    ls)     printf '[]\n'; exit 0 ;;                   # no running projects -> no teardown
    down)   printf 'DOWN %s\n' "\$*" >> "\$STUB_LOG"; exit 0 ;;
  esac
done
exit 0
STUB
chmod +x "$bin/docker"

# A remote dir with two stacks (no .env, so no --env-file / registry-login path).
mkremote() {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/app" "$d/web" "$d/docs"
  if [ "${BROKEN:-false}" = true ]; then
    mkdir -p "$d/broken"
    printf 'not: [valid\n' > "$d/broken/docker-compose.yml"
  fi
  if [ "${LINK:-false}" = true ]; then ln -s app "$d/alias"; fi
  printf 'services:\n  x:\n    image: busybox\n' > "$d/app/docker-compose.yml"
  printf 'services:\n  x:\n    image: busybox\n' > "$d/web/docker-compose.yml"
  for stack in app web; do
    printf '%s\n' '{"name":"test","services":{"web":{"image":"nginx:1","cap_drop":["ALL"],"ports":[{"target":80,"published":"8080","host_ip":"127.0.0.1"}]}}}' > "$d/$stack/resolved.json"
  done
  if [ "${UNSAFE:-false}" = true ]; then sed 's/127.0.0.1/0.0.0.0/' "$d/web/resolved.json" > "$d/web/new"; mv "$d/web/new" "$d/web/resolved.json"; fi
  if [ "${BINDLINK:-false}" = true ]; then
    ln -s /etc "$d/web/data"
    printf '{"services":{"web":{"image":"nginx:1","cap_drop":["ALL"],"volumes":[{"type":"bind","source":"%s","target":"/mnt"}]}}}' "$d/web/data" > "$d/web/resolved.json"
  fi
  if [ "${NAMED_BIND:-false}" = true ]; then
    printf '{"services":{"web":{"image":"nginx:1","cap_drop":["ALL"],"volumes":[{"type":"volume","source":"hostetc","target":"/mnt"}]}},"volumes":{"hostetc":{"driver":"local","driver_opts":{"type":"none","o":"bind","device":"%s"}}}}' "${BIND_DEVICE:-/etc}" > "$d/web/resolved.json"
  fi
  printf '%s' "$d"
}

# run_body <FORCE_RECREATE> <ONLY_STACK> -> sets: RC, LOG (path to recorded ups)
run_body() {
  local force="$1" only="$2" d log rc=0
  d="$(mkremote)"; log="$TMP/log.$RANDOM"; : > "$log"
  STUB_LOG="$log" PATH="$bin:$PATH" bash "$BODY" "$d" "$force" "$only" "$(base64 < "$ROOT/tests/stack_policy_check.py" | tr -d '\n')" >"$TMP/out" 2>&1 || rc=$?
  RC=$rc; LOG="$log"; OUT="$(cat "$TMP/out")"; rm -rf "$d"
}

# Each log line is `UP <stack> up -d --pull always --remove-orphans [--force-recreate]`,
# the stack identified by the cwd the compose ran in (not an arg).

# 1) No targeting: both stacks come up, none forced.
run_body false ''
[ "$RC" -eq 0 ] || fail "no-target: expected rc0, got $RC: $OUT"
grep -q '^UP app ' "$LOG" && grep -q '^UP web ' "$LOG" || fail "no-target: both stacks must come up, log: $(cat "$LOG")"
grep -q -- '--force-recreate' "$LOG" && fail "no-target: must NOT force-recreate, log: $(cat "$LOG")"

# 2) Single-stack target: ONLY that stack comes up (sibling skipped).
run_body false app
[ "$RC" -eq 0 ] || fail "target-app: expected rc0, got $RC: $OUT"
grep -q '^UP app ' "$LOG" || fail "target-app: app must come up, log: $(cat "$LOG")"
grep -q '^UP web ' "$LOG" && fail "target-app: web must be skipped, log: $(cat "$LOG")"

# 3) force_recreate: the up for the target carries --force-recreate.
run_body true app
[ "$RC" -eq 0 ] || fail "force-app: expected rc0, got $RC: $OUT"
grep -q '^UP app .*--force-recreate' "$LOG" || fail "force-app: app's up must include --force-recreate, log: $(cat "$LOG")"

# 4) Stack not found -> loud failure (rc!=0, clear error), NOT a silent green no-op.
run_body true nonexistent
[ "$RC" -ne 0 ] || fail "stack-not-found: must FAIL (rc!=0), got rc0 no-op: $OUT"
printf '%s' "$OUT" | grep -q "not found" || fail "stack-not-found: must emit a 'not found' error, got: $OUT"
grep -q '^UP ' "$LOG" && fail "stack-not-found: nothing should have come up, log: $(cat "$LOG")"

# 5) Target a PRESENT but INVALID compose dir -> loud failure too (stack_matched
#    counts only stacks that pass `config -q`, so a broken target is not a green
#    no-op). Regression for the Round-3 finding.
BROKEN=true run_body true broken
[ "$RC" -ne 0 ] || fail "invalid-target: must FAIL (rc!=0), got rc0 no-op: $OUT"
printf '%s' "$OUT" | grep -q "not a valid compose project" || fail "invalid-target: must emit the not-valid error, got: $OUT"
grep -q '^UP ' "$LOG" && fail "invalid-target: nothing should have come up, log: $(cat "$LOG")"

UNSAFE=true run_body false ''
[ "$RC" -ne 0 ] || fail "unsafe resolved config must fail"
grep -q '^UP ' "$LOG" && fail "no stack may start before every selected stack passes"
printf '%s' "$OUT" | grep -q 'must bind' || fail "expected actual policy rejection"
BROKEN=true run_body false ''
[ "$RC" -ne 0 ] || fail "invalid compose in full deploy must fail"
grep -q '^UP ' "$LOG" && fail "invalid sibling must block all starts"

LINK=true run_body false ''
[ "$RC" -ne 0 ] || fail "symlink stack must be refused"
grep -q '^UP ' "$LOG" && fail "symlink sibling must block all starts"
printf '%s' "$OUT" | grep -q 'symbolic link' || fail "expected explicit symlink rejection"
BINDLINK=true run_body false ''
[ "$RC" -ne 0 ] || fail "bind source symlink to /etc must be refused"
grep -q '^UP ' "$LOG" && fail "unsafe bind source must block all starts"
printf '%s' "$OUT" | grep -q 'sensitive host path' || fail "expected sensitive mount policy rejection"
NAMED_BIND=true run_body false ''
[ "$RC" -ne 0 ] || fail "named local volume bind to /etc must be refused"
grep -q '^UP ' "$LOG" && fail "unsafe named volume must block all starts"
printf '%s' "$OUT" | grep -q 'sensitive host path' || fail "expected named volume policy rejection"
NAMED_BIND=true BIND_DEVICE=/srv/app-data run_body false ''
[ "$RC" -eq 0 ] || fail "non-sensitive local bind must remain deployable: $OUT"
grep -q '^UP web ' "$LOG" || fail "safe named volume never deployed"
echo "ALL REMOTE-LOOP CHECKS PASSED"
