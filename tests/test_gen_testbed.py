"""Tests for verify/lib/gen_testbed.py: authenticate, resolve a lab id from
its title, fetch the pyATS testbed, and the CLI's file handling, all against
tests/fake_cml_testbed_api.py (no mocks)."""
from __future__ import annotations

import os
import stat
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "verify" / "lib"))
import gen_testbed  # noqa: E402

PORT = 18007
BASE_URL = f"http://127.0.0.1:{PORT}"
LAB_TITLE = "TrustSec Demo"


class PatchTerminalServerCredentialsTest(unittest.TestCase):
    """gen_testbed.patch_terminal_server_credentials, no server needed."""

    PLACEHOLDER_BLOCK = (
        "  terminal_server:\n"
        "    connections:\n"
        "      cli:\n"
        "        ip: 198.51.100.9\n"
        "        port: 22\n"
        "        protocol: ssh\n"
        "    credentials:\n"
        "      default:\n"
        "        password: change_me\n"
        "        username: change_me\n"
        "    os: linux\n"
        "    type: server\n"
    )

    def test_replaces_placeholder_with_real_credentials(self) -> None:
        out = gen_testbed.patch_terminal_server_credentials(
            self.PLACEHOLDER_BLOCK, "admin", "s3cret"
        )
        self.assertNotIn("change_me", out)
        self.assertIn("password: 's3cret'", out)
        self.assertIn("username: 'admin'", out)

    def test_leaves_other_devices_credentials_untouched(self) -> None:
        text = "  switch1:\n    credentials:\n      default:\n        username: cisco\n" + self.PLACEHOLDER_BLOCK
        out = gen_testbed.patch_terminal_server_credentials(text, "admin", "s3cret")
        self.assertIn("username: cisco", out)

    def test_quotes_a_single_quote_in_the_password(self) -> None:
        out = gen_testbed.patch_terminal_server_credentials(
            self.PLACEHOLDER_BLOCK, "admin", "it's-a-secret"
        )
        self.assertIn("password: 'it''s-a-secret'", out)

    def test_raises_when_placeholder_is_absent(self) -> None:
        with self.assertRaisesRegex(gen_testbed.TestbedError, "change_me placeholder not found"):
            gen_testbed.patch_terminal_server_credentials("testbed:\n  name: x\n", "admin", "s3cret")


class FetchTestbedTest(unittest.TestCase):
    proc: subprocess.Popen

    @classmethod
    def setUpClass(cls) -> None:
        cls.proc = subprocess.Popen(
            [sys.executable, str(REPO / "tests" / "fake_cml_testbed_api.py"), str(PORT)]
        )
        for _ in range(50):
            try:
                with urllib.request.urlopen(f"{BASE_URL}/api/v0/labs", timeout=1):
                    pass
                break
            except urllib.error.HTTPError:
                break
            except OSError:
                time.sleep(0.1)

    @classmethod
    def tearDownClass(cls) -> None:
        cls.proc.terminate()
        cls.proc.wait(timeout=5)

    def test_authenticate_returns_token(self) -> None:
        token = gen_testbed.authenticate(BASE_URL, "admin", "secret")
        self.assertEqual(token, "FAKE-TOKEN")

    def test_authenticate_bad_credentials_raises(self) -> None:
        with self.assertRaisesRegex(gen_testbed.TestbedError, "HTTP 403"):
            gen_testbed.authenticate(BASE_URL, "admin", "wrong")

    def test_fetch_testbed_returns_yaml_for_known_title(self) -> None:
        token = gen_testbed.authenticate(BASE_URL, "admin", "secret")
        testbed = gen_testbed.fetch_testbed(BASE_URL, token, LAB_TITLE)
        self.assertIn("testbed:", testbed)
        self.assertIn("trustsec-demo", testbed)

    def test_fetch_testbed_raises_on_unknown_title(self) -> None:
        token = gen_testbed.authenticate(BASE_URL, "admin", "secret")
        with self.assertRaisesRegex(gen_testbed.TestbedError, "Nope"):
            gen_testbed.fetch_testbed(BASE_URL, token, "Nope")

    def test_fetch_testbed_bad_token_raises_401(self) -> None:
        with self.assertRaisesRegex(gen_testbed.TestbedError, "HTTP 401"):
            gen_testbed.fetch_testbed(BASE_URL, "not-a-real-token", LAB_TITLE)

    def test_cli_writes_out_file_mode_0600_and_no_secret_leak(self) -> None:
        with tempfile.TemporaryDirectory(prefix=".tmp.gen_testbed.", dir=REPO / "tests") as tmp:
            out_path = Path(tmp) / "testbed.yaml"
            env = dict(os.environ)
            env.update({
                "CML_URL": BASE_URL,
                "CML_USERNAME": "admin",
                "CML_PASSWORD": "secret",
                "CML_VERIFY_SSL": "false",
            })
            result = subprocess.run(
                [sys.executable, str(REPO / "verify" / "lib" / "gen_testbed.py"), LAB_TITLE, str(out_path)],
                env=env, capture_output=True, text=True, timeout=30,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), str(out_path))
            self.assertNotIn("secret", result.stdout)
            self.assertNotIn("secret", result.stderr)
            self.assertNotIn("FAKE-TOKEN", result.stdout)
            self.assertNotIn("FAKE-TOKEN", result.stderr)
            self.assertEqual(stat.S_IMODE(out_path.stat().st_mode), 0o600)
            written = out_path.read_text()
            self.assertIn("testbed:", written)
            # The terminal_server proxy's change_me placeholder must come
            # out patched with the real CML login, or every device
            # connection fails through the proxy (caught live, Task 7).
            self.assertNotIn("change_me", written)
            self.assertIn("username: 'admin'", written)

    def test_cli_unknown_lab_title_fails_without_writing(self) -> None:
        with tempfile.TemporaryDirectory(prefix=".tmp.gen_testbed.", dir=REPO / "tests") as tmp:
            out_path = Path(tmp) / "testbed.yaml"
            env = dict(os.environ)
            env.update({
                "CML_URL": BASE_URL,
                "CML_USERNAME": "admin",
                "CML_PASSWORD": "secret",
                "CML_VERIFY_SSL": "false",
            })
            result = subprocess.run(
                [sys.executable, str(REPO / "verify" / "lib" / "gen_testbed.py"), "Nope", str(out_path)],
                env=env, capture_output=True, text=True, timeout=30,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(out_path.exists())
            self.assertNotIn("secret", result.stderr)


if __name__ == "__main__":
    unittest.main()
