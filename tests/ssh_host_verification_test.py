#!/usr/bin/env python3
"""Exercise deploy preconditions and SSH argv without making network calls."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class HostVerificationTests(unittest.TestCase):
    def run_deploy(self, known_hosts):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "fleet/stacks/test/app").mkdir(parents=True)
            (root / "bin").mkdir()
            for name in ("ssh", "rsync"):
                stub = root / "bin" / name
                stub.write_text("#!/usr/bin/env python3\nimport json,os,sys\n"
                                "with open(os.environ['CALLS'], 'a') as f:\n"
                                "    f.write(json.dumps(sys.argv) + '\\n')\n")
                stub.chmod(0o700)
            env = dict(os.environ, PATH=str(root / "bin") + ":" + os.environ["PATH"],
                       GITHUB_WORKSPACE=tmp, SERVER="test", SSH_HOST="example.invalid",
                       SSH_USER="deploy", SSH_PRIVATE_KEY="test-only", SSH_PORT="22",
                       SSH_KNOWN_HOSTS=known_hosts, ONLY_STACK="", FORCE_RECREATE="false",
                       STACKS_DIR="fleet/stacks", REMOTE_STACKS_DIR="/opt/stacks",
                       CALLS=str(root / "calls"))
            result = subprocess.run(["bash", str(ROOT / ".github/scripts/deploy-server.sh")],
                                    env=env, capture_output=True, text=True)
            calls = [json.loads(line) for line in (root / "calls").read_text().splitlines()] if (root / "calls").exists() else []
            return result, calls

    def test_missing_pin_fails_before_network(self):
        result, calls = self.run_deploy("")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No SSH_KNOWN_HOSTS", result.stderr)
        self.assertEqual(calls, [])

    def test_both_transports_are_strict_and_empty_argument_survives(self):
        result, calls = self.run_deploy("example.invalid ssh-ed25519 TEST_FIXTURE")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 2)
        rsync, ssh = calls
        self.assertIn("StrictHostKeyChecking=yes", rsync[rsync.index("-e") + 1])
        self.assertIn("StrictHostKeyChecking=yes", ssh)
        args = shlex.split(ssh[-1])
        self.assertEqual(args[:6], ["bash", "-s", "--", "/opt/stacks", "false", ""])
        self.assertTrue(args[6])  # actual trusted checker payload


if __name__ == "__main__":
    unittest.main()
