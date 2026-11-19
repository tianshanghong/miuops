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
# Passes (exit 0) AND prints an advisory warning whose text matches $2.
expect_warn() {
  out="$("$PY" "$CHECK" "$FIX/$1" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "$2"; then
    echo "ok   (warn):   $1"
  else
    echo "FAIL (warn):   expected $1 to pass(0) with warning matching '$2' (rc=$rc)"; fail=1
  fi
}
# Passes (exit 0) AND prints NO image warning.
expect_nowarn() {
  out="$("$PY" "$CHECK" "$FIX/$1" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -qiE "digest|:latest|untagged"; then
    echo "ok   (nowarn): $1"
  else
    echo "FAIL (nowarn): expected $1 to pass(0) with no image warning (rc=$rc)"; fail=1
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
expect_fail bad-netmode-bridge.yml
expect_fail bad-external-bridge.yml
expect_fail bad-external-bridge-legacy.yml
expect_fail bad-external-default-bridge.yml
expect_fail bad-mount-etc.yml
expect_fail bad-security-opt-equals.yml
expect_pass good-localtime.yml

expect_fail bad-mount-dotdot.yml
expect_fail bad-mount-dotslash.yml
expect_fail bad-mount-cloudflared.yml
expect_fail bad-mount-backup-env.yml
expect_fail bad-secret-host-file.yml
expect_fail bad-config-host-file.yml
expect_fail bad-volumes-from.yml
expect_fail bad-pid-service.yml
expect_fail bad-netmode-service.yml
expect_fail bad-envfile-sensitive.yml
expect_pass good-volumes-and-local-bind.yml
expect_fail bad-mount-parent-escape.yml
expect_fail bad-mount-local-rw.yml
expect_fail bad-mount-local-forbidden.yml

if PYTHONPATH="$DIR" "$PY" - <<'PY'; then
import os, tempfile
import stack_policy_check as spc

assert spc._volume_bind_source("andon_data:/data") is None
assert spc._volume_bind_source({"type": "volume", "source": "andon_data", "target": "/data"}) is None
assert spc._volume_bind_source("./nginx.conf:/etc/nginx/conf.d/default.conf:ro") == "./nginx.conf"
assert spc._volume_bind_source("${HOST_DIR:-/etc}:/mnt:ro") == "${HOST_DIR:-/etc}:/mnt:ro"

assert not spc._is_volume_read_only("./nginx.conf:/etc/nginx/conf.d/default.conf")
assert not spc._is_volume_read_only("./nginx.conf:/etc/nginx/conf.d/default.conf:rw")
assert not spc._is_volume_read_only("./nginx.conf:/etc/nginx/conf.d/default.conf:ro,rw")
assert not spc._is_volume_read_only("./nginx.conf:/etc/nginx/nginx.conf:ro:rw")
assert spc._is_volume_read_only("./nginx.conf:/etc/nginx/conf.d/default.conf:ro")
assert spc._is_volume_read_only("./nginx.conf:/etc/nginx/conf.d/default.conf:ro,z")
assert spc._is_volume_read_only({"type": "bind", "source": "./nginx.conf", "target": "/etc/nginx/nginx.conf", "read_only": True})
assert not spc._is_volume_read_only({"type": "bind", "source": "./nginx.conf", "target": "/etc/nginx/nginx.conf"})

opt_base = "/opt/stacks/well-known"
assert not spc._is_sensitive_resolved_mount("/opt/stacks/well-known/nginx.conf", base_dir=opt_base)
assert spc._is_sensitive_resolved_mount("/opt/stacks/.env", base_dir=opt_base)
assert spc._is_sensitive_resolved_mount("/opt/stacks/other/nginx.conf", base_dir=opt_base)
assert spc._is_sensitive_resolved_mount("../.env", base_dir=opt_base)
assert spc._is_sensitive_resolved_mount(".", base_dir=opt_base)
assert spc._is_sensitive_resolved_mount("${HOST_DIR:-/etc}:/mnt:ro", base_dir=opt_base)
assert spc._is_sensitive_resolved_mount("./docker-compose.yml", base_dir=opt_base)
assert spc._is_sensitive_resolved_mount("./.env", base_dir=opt_base)
assert spc._is_sensitive_resolved_mount("./app.env", base_dir=opt_base)
assert spc._is_sensitive_resolved_mount("./app.env", base_dir=opt_base, allow_env_ext=False)
assert not spc._is_sensitive_resolved_mount("./app.env", base_dir=opt_base, allow_env_ext=True)
assert spc._is_sensitive_resolved_mount("./.miuops-config.123", base_dir=opt_base)
assert spc._is_sensitive_resolved_mount("./.git/config", base_dir=opt_base)
assert spc._is_stack_local_mount("/opt/stacks/well-known/data", base_dir=opt_base)

assert spc._scan_pre_config_text("services:\n  x:\n    env_file:\n      /etc/shadow\n", "compose.yml", opt_base)

with tempfile.TemporaryDirectory() as tmp_stack:
    conf = os.path.join(tmp_stack, "conf")
    os.makedirs(conf)
    with open(os.path.join(conf, "nginx.conf"), "w") as f:
        f.write("server {}\n")
    assert not spc._is_sensitive_resolved_mount("./conf", base_dir=tmp_stack)

    with open(os.path.join(conf, "secret.env"), "w") as f:
        f.write("SECRET=1\n")
    assert spc._is_sensitive_resolved_mount("./conf", base_dir=tmp_stack)
    os.remove(os.path.join(conf, "secret.env"))

    os.symlink("/etc/hosts", os.path.join(conf, "evil"))
    assert spc._is_sensitive_resolved_mount("./conf", base_dir=tmp_stack)

    comp = os.path.join(tmp_stack, "docker-compose.yml")
    with open(comp, "w") as f:
        f.write(
            "services:\n  web:\n    image: nginx:1\n    cap_drop: [ALL]\n"
            "    label_file: ./app.env\n    volumes:\n      - data_vol:/data\n"
            f"volumes:\n  data_vol:\n    driver: local\n    driver_opts:\n      type: none\n      o: bind\n      device: {tmp_stack}/data\n"
        )
    viols, _ = spc.check_file(comp)
    assert any("label_file" in v for v in viols), viols
    assert any("data_vol" in v for v in viols), viols

ci_base = "/home/runner/work/fleet/stacks/s/well-known"
assert not spc._is_sensitive_resolved_mount("/home/runner/work/fleet/stacks/s/well-known/nginx.conf", base_dir=ci_base)
assert not spc._is_sensitive_resolved_mount("./nginx.conf", base_dir=ci_base)
assert spc._is_sensitive_resolved_mount("/home/runner/.ssh/id_rsa", base_dir=ci_base)
assert spc._is_sensitive_resolved_mount("../.env", base_dir=ci_base)
PY
  echo "ok   (pass):   _is_sensitive_resolved_mount Linux/host base_dir cases"
else
  echo "FAIL (pass):   _is_sensitive_resolved_mount Linux/host base_dir cases"; fail=1
fi

# Image pin: an un-pinned image warns (but still passes); a digest-pinned image is silent.
expect_warn warn-unpinned-image.yml "digest"
expect_nowarn good-pinned-image.yml

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
