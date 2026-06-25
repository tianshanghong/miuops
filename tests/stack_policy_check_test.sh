#!/usr/bin/env bash
# Self-test for stack_policy_check.py: compliant fixtures pass, violating fixtures are rejected.
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK="$DIR/stack_policy_check.py"
FIX="$DIR/fixtures/stack_policy"
PY="${PYTHON:-python3}"
fail=0

if ! "$PY" -c "import yaml" 2>/dev/null; then
  echo "SKIP: PyYAML not available for $PY (set PYTHON=… to a interpreter with pyyaml)"
  exit 0
fi

expect_pass() {
  if "$PY" "$CHECK" "$FIX/$1" >/dev/null 2>&1; then
    echo "ok   (pass):   $1"
  else
    echo "FAIL (pass):   expected $1 to pass but it was rejected"; fail=1
  fi
}
expect_fail() {
  if "$PY" "$CHECK" "$FIX/$1" >/dev/null 2>&1; then
    echo "FAIL (reject): expected $1 to be rejected but it passed"; fail=1
  else
    echo "ok   (reject): $1"
  fi
}

expect_pass good.yml
expect_pass good-loopback-longform.yml
expect_pass good-hostnet-optin.yml
expect_fail bad-public-port.yml
expect_fail bad-zeroaddr.yml
expect_fail bad-privileged.yml
expect_fail bad-no-capdrop.yml
expect_fail bad-hostnet.yml
expect_pass good-loopback-ipv6.yml
expect_fail bad-privileged-string.yml
expect_fail bad-capadd-sysadmin.yml
expect_fail bad-docker-sock.yml
expect_fail bad-hostpath.yml
expect_fail bad-pid-host.yml
expect_fail bad-security-opt.yml
expect_fail bad-devices.yml
expect_fail bad-cap-prefix.yml
expect_fail bad-cgroup-host.yml
expect_fail bad-userns-host.yml
expect_fail bad-netmode-container.yml
expect_fail bad-mount-etc.yml
expect_fail bad-security-opt-equals.yml
expect_pass good-localtime.yml

expect_fail bad-mount-dotdot.yml
expect_fail bad-mount-dotslash.yml

# A batch containing any violating file must fail as a whole.
if "$PY" "$CHECK" "$FIX/good.yml" "$FIX/bad-privileged.yml" >/dev/null 2>&1; then
  echo "FAIL (reject): a batch containing a bad file should be rejected"; fail=1
else
  echo "ok   (reject): batch good.yml + bad-privileged.yml"
fi

if [ "$fail" -eq 0 ]; then
  echo "ALL STACK POLICY-CHECK TESTS PASSED"
else
  echo "STACK POLICY-CHECK TESTS FAILED"
fi
exit "$fail"
