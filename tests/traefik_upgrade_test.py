#!/usr/bin/env python3
"""Exercise the deployed Traefik version gate and systemd hardening with real Ansible tasks."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

import yaml
from jinja2 import Environment, StrictUndefined

ROOT = Path(__file__).resolve().parents[1]
ROLE = ROOT / "roles/traefik"


class TraefikUpgradeTest(unittest.TestCase):
    def test_service_uses_installed_binary_and_hardened_sandbox(self):
        defaults = yaml.safe_load((ROLE / "defaults/main.yml").read_text())
        self.assertEqual(defaults.get("traefik_bin"), "/usr/local/bin/traefik")
        self.assertIn("@sha256:", defaults.get("traefik_proxy_image", ""))
        defaults["ansible_managed"] = "Managed by Ansible"
        env = Environment(undefined=StrictUndefined)
        env.filters["comment"] = lambda s: f"# {s}"
        traefik_unit = env.from_string((ROLE / "templates/traefik.service.j2").read_text()).render(**defaults)
        self.assertIn("ExecStart=/usr/local/bin/traefik --configfile=/etc/traefik/traefik.yml", traefik_unit)
        self.assertIn("NoNewPrivileges=true", traefik_unit)
        self.assertIn("CapabilityBoundingSet=", traefik_unit)
        proxy_unit = env.from_string(
            (ROLE / "templates/docker-socket-proxy.service.j2").read_text()
        ).render(**defaults)
        self.assertIn("-e POST=0 -e CONTAINERS=1 -e NETWORKS=1", proxy_unit)
        self.assertIn("-p 127.0.0.1:2375:2375", proxy_unit)

    def check_version(self, output, expected_success, exit_code=0):
        with tempfile.TemporaryDirectory(prefix="miuops-traefik-") as tmp:
            tmp = Path(tmp)
            binary = tmp / "traefik"
            binary.write_text(
                "#!" + sys.executable + "\nprint(" + repr(output) + ")\nraise SystemExit(" + str(exit_code) + ")\n"
            )
            binary.chmod(0o755)
            playbook = tmp / "check.yml"
            playbook.write_text(json.dumps([{
                "hosts": "localhost", "gather_facts": False,
                "vars": {"traefik_bin": str(binary)},
                "tasks": [{"ansible.builtin.include_tasks": str(ROLE / "tasks/verify.yml")}],
            }]))
            env = dict(os.environ, ANSIBLE_HOME=str(tmp / "ansible"), ANSIBLE_NOCOLOR="1")
            result = subprocess.run(
                ["ansible-playbook", "-i", "localhost,", "-c", "local", str(playbook)],
                text=True, capture_output=True, env=env, timeout=60,
            )
            self.assertEqual(result.returncode == 0, expected_success, result.stdout + result.stderr)
            if not expected_success and not exit_code:
                self.assertIn("3.7.19", result.stdout)

    def test_fixed_version_is_accepted(self):
        self.check_version("Version:      3.7.19\nCodename:     cheddar\n", True)

    def test_v_prefixed_newer_version_is_accepted(self):
        self.check_version("Version:      v3.7.20\nCodename:     cheddar\n", True)

    def test_vulnerable_versions_are_rejected(self):
        self.check_version("Version:      3.7.18\nCodename:     cheddar\n", False)
        self.check_version("Version:      3.7.16\nCodename:     cheddar\n", False)

    def test_unknown_version_is_rejected(self):
        self.check_version("unknown development build", False)

    def test_failed_binary_is_rejected(self):
        self.check_version("cannot execute", False, exit_code=1)

    @unittest.skipUnless(Path("/proc/self/exe").exists(), "requires Linux /proc/<pid>/exe")
    def check_running_binary(self, replaced):
        # Reproduce an interrupted upgrade: replace the executable on disk while
        # its old inode remains running; a later apply must request a restart.
        with tempfile.TemporaryDirectory(prefix="miuops-traefik-running-") as tmp:
            tmp = Path(tmp)
            binary = tmp / "sleep"
            shutil.copy2(shutil.which("sleep"), binary)
            process = subprocess.Popen(["sleep", "60"], executable=str(binary))
            try:
                time.sleep(0.05)  # Let multicall coreutils select its sleep applet.
                self.assertIsNone(process.poll(), "Test process failed to start")
                if replaced:
                    replacement = tmp / "replacement"
                    shutil.copy2(shutil.which("sleep"), replacement)
                    replacement.replace(binary)
                systemctl = tmp / "systemctl"
                systemctl.write_text("#!/bin/sh\necho " + str(process.pid) + "\n")
                systemctl.chmod(0o755)
                marker = tmp / "restarted"
                playbook = tmp / "running.yml"
                playbook.write_text(json.dumps([{
                    "hosts": "localhost", "gather_facts": False,
                    "vars": {"traefik_bin": str(binary)},
                    "tasks": [
                        {"ansible.builtin.include_tasks": str(ROLE / "tasks/running.yml")},
                        {"ansible.builtin.meta": "flush_handlers"},
                    ],
                    "handlers": [{"name": "Restart traefik", "ansible.builtin.copy": {
                        "dest": str(marker), "content": "restarted", "mode": "0600",
                    }}],
                }]))
                env = dict(os.environ, ANSIBLE_HOME=str(tmp / "ansible"),
                           PATH=str(tmp) + os.pathsep + os.environ["PATH"])
                result = subprocess.run(
                    ["ansible-playbook", "-i", "localhost,", "-c", "local", str(playbook)],
                    text=True, capture_output=True, env=env, timeout=60,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIsNone(process.poll(), "Test process exited before inode comparison")
                self.assertEqual(marker.exists(), replaced, result.stdout)
            finally:
                process.terminate()
                process.wait(timeout=5)

    @unittest.skipUnless(Path("/proc/self/exe").exists(), "requires Linux /proc/<pid>/exe")
    def test_retry_after_interrupted_upgrade_restarts_old_process(self):
        self.check_running_binary(replaced=True)

    @unittest.skipUnless(Path("/proc/self/exe").exists(), "requires Linux /proc/<pid>/exe")
    def test_current_process_does_not_restart(self):
        self.check_running_binary(replaced=False)


if __name__ == "__main__":
    unittest.main()
