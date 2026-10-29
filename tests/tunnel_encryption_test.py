#!/usr/bin/env python3
"""Exercise the real CLI helper with disposable SOPS/age keys and fault injection."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOPS = shutil.which("sops")
AGE_KEYGEN = shutil.which("age-keygen")
TID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
SECRET = "synthetic-tunnel-secret-must-never-enter-the-fleet"


class TunnelEncryptionTest(unittest.TestCase):
    def setUp(self):
        self.assertTrue(SOPS and AGE_KEYGEN, "sops and age-keygen are required")
        self.temp = tempfile.TemporaryDirectory(prefix="miuops-tunnel-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.fleet = self.root / "fleet"
        self.secrets = self.fleet / "secrets"
        self.secrets.mkdir(parents=True)
        self.source = self.root / "home" / ".cloudflared" / f"{TID}.json"
        self.source.parent.mkdir(parents=True)
        self.credential = {"AccountTag": "synthetic-account", "TunnelID": TID,
                           "TunnelSecret": SECRET, "Endpoint": ""}
        self.source.write_text(json.dumps(self.credential))
        self.source.chmod(0o400)
        self.destination = self.secrets / self.source.name
        self.key = self.root / "identity.txt"
        subprocess.run([AGE_KEYGEN, "-o", str(self.key)], check=True, capture_output=True)
        recipient = subprocess.check_output([AGE_KEYGEN, "-y", str(self.key)], text=True).strip()
        self.config = self.root / ".sops.yaml"
        self.config.write_text("creation_rules:\n"
                               "  - path_regex: ^fleet/secrets/.*\\.json$\n"
                               f"    age: {recipient}\n")
        # Isolate the child process's home and key discovery from the operator.
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(("SOPS_", "MIUOPS_", "AGE_"))}
        self.env.update(HOME=str(self.source.parent.parent),
                        XDG_CONFIG_HOME=str(self.root / "config"),
                        SOPS_AGE_KEY_FILE=str(self.key),
                        MIUOPS_FLEET_DIR=str(self.fleet))
        self.command = ["bash", "-c",
                        'source "$1" --source-only; sops_encrypt_tunnel_cred "$2"',
                        "tunnel-test", str(ROOT / "miuops"), TID]

    def run_helper(self):
        return subprocess.run(self.command, env=self.env, cwd=self.root,
                              capture_output=True, text=True, timeout=15)

    def assert_no_plaintext(self):
        for path in self.fleet.rglob("*"):
            if path.is_file():
                self.assertNotIn(SECRET.encode(), path.read_bytes(), str(path))

    def test_readonly_source_roundtrip_and_keyless_retry(self):
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        ciphertext = self.destination.read_bytes()
        self.assert_no_plaintext()
        self.assertEqual(self.destination.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.source.stat().st_mode & 0o777, 0o400)
        decrypted = subprocess.check_output([SOPS, "--decrypt", str(self.destination)],
                                            env=self.env, cwd=self.root)
        self.assertEqual(json.loads(decrypted), self.credential)
        self.key.unlink()
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.destination.read_bytes(), ciphertext)
        self.assertEqual(list(self.secrets.iterdir()), [self.destination])

    def test_existing_plaintext_is_rejected_without_overwrite(self):
        self.destination.write_bytes(self.source.read_bytes())
        original = self.destination.read_bytes()
        result = self.run_helper()
        self.assertNotEqual(result.returncode, 0, "plaintext was reported as encrypted")
        self.assertNotIn("already present", result.stdout)
        self.assertEqual(self.destination.read_bytes(), original)

    def test_partially_encrypted_existing_file_is_rejected(self):
        self.assertEqual(self.run_helper().returncode, 0)
        document = json.loads(self.destination.read_text())
        document["TunnelSecret"] = SECRET
        self.destination.write_text(json.dumps(document))
        result = self.run_helper()
        self.assertNotEqual(result.returncode, 0, "SOPS metadata alone cannot prove encryption")
        self.assertNotIn("already present", result.stdout)

    def test_failed_encryption_leaves_no_output(self):
        self.config.write_text("creation_rules: []\n")
        result = self.run_helper()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(self.secrets.iterdir()), [])

    def test_creation_rule_cannot_leave_credential_fields_plaintext(self):
        with self.config.open("a") as handle:
            handle.write("    encrypted_regex: ^AccountTag$\n")
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_no_plaintext()
        decrypted = subprocess.check_output([SOPS, "--decrypt", str(self.destination)],
                                            env=self.env, cwd=self.root)
        self.assertEqual(json.loads(decrypted), self.credential)

    def test_interrupted_before_encryption_never_publishes_plaintext(self):
        self.interrupt_encryption(after_output=False)

    def test_interrupted_after_encryption_never_publishes_partial_output(self):
        self.interrupt_encryption(after_output=True)

    def interrupt_encryption(self, after_output):
        # Pause at the encryptor boundary, after any caller-side copy has happened.
        # Kill the entire child process group: SIGKILL deliberately bypasses traps.
        marker = self.root / "encryptor-entered"
        bindir = self.root / "bin"
        bindir.mkdir()
        wrapper = bindir / "sops"
        wrapper.write_text("#!/usr/bin/env python3\n"
                           "import os, pathlib, subprocess, sys, time\n"
                           "if '--encrypt' in sys.argv:\n"
                           f"    if {after_output!r}:\n"
                           f"        result = subprocess.run([{SOPS!r}] + sys.argv[1:], check=True, stdout=subprocess.PIPE)\n"
                           "        sys.stdout.buffer.write(result.stdout)\n"
                           "        sys.stdout.buffer.flush()\n"
                           f"    pathlib.Path({str(marker)!r}).touch()\n"
                           "    time.sleep(60)\n"
                           f"os.execv({SOPS!r}, [{SOPS!r}] + sys.argv[1:])\n")
        wrapper.chmod(0o700)
        self.env["PATH"] = str(bindir) + os.pathsep + self.env["PATH"]
        with subprocess.Popen(self.command, env=self.env, cwd=self.root,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              start_new_session=True) as process:
            try:
                deadline = time.monotonic() + 5
                while not marker.exists() and process.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(marker.exists(), "helper never reached encryption")
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                process.communicate(timeout=5)
        self.assertFalse(self.destination.exists(), "interrupted output was published")
        self.assert_no_plaintext()
        self.env["PATH"] = os.environ["PATH"]
        self.assertEqual(self.run_helper().returncode, 0)
        self.assert_no_plaintext()


if __name__ == "__main__":
    unittest.main()
