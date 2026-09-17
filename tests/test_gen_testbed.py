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


class PatchDeviceCredentialsTest(unittest.TestCase):
    """gen_testbed.patch_device_credentials, no server needed."""

    DEVICES_TEXT = (
        "devices:\n"
        "  blue-endpoint:\n"
        "    credentials:\n"
        "      default:\n"
        "        password: cisco\n"
        "        username: cisco\n"
        "    os: linux\n"
        "    type: server\n"
        "  kind-host:\n"
        "    credentials:\n"
        "      default:\n"
        "        password: cisco\n"
        "        username: cisco\n"
        "    os: linux\n"
        "    type: server\n"
        "  spine1:\n"
        "    credentials:\n"
        "      default:\n"
        "        password: cisco\n"
        "        username: cisco\n"
        "    os: nxos\n"
        "    platform: n9k\n"
        "    type: switch\n"
        "  terminal_server:\n"
        "    credentials:\n"
        "      default:\n"
        "        password: 'admin'\n"
        "        username: 'admin'\n"
        "    os: linux\n"
        "    type: server\n"
    )

    def test_nxos_device_gets_admin_username(self) -> None:
        out = gen_testbed.patch_device_credentials(self.DEVICES_TEXT, "labrats1")
        spine_block = out.split("  spine1:\n", 1)[1].split("  terminal_server:\n", 1)[0]
        self.assertIn("username: 'admin'", spine_block)
        self.assertIn("password: 'labrats1'", spine_block)

    def test_iosxe_device_gets_admin_username(self) -> None:
        text = (
            "devices:\n"
            "  edge:\n"
            "    credentials:\n"
            "      default:\n"
            "        password: cisco\n"
            "        username: cisco\n"
            "    os: iosxe\n"
        )
        out = gen_testbed.patch_device_credentials(text, "labpw")
        self.assertIn("        username: 'admin'\n", out)
        self.assertNotIn("username: cisco", out)

    def test_linux_host_keeps_cisco_username(self) -> None:
        out = gen_testbed.patch_device_credentials(self.DEVICES_TEXT, "labrats1")
        host_block = out.split("  blue-endpoint:\n", 1)[1].split("  kind-host:\n", 1)[0]
        self.assertIn("username: 'cisco'", host_block)
        self.assertIn("password: 'labrats1'", host_block)

    def test_kind_host_gets_kindops_username_override(self) -> None:
        # kind-host is a Linux host like blue-endpoint/red-endpoint, but
        # its real day-0 username is kindops, not cisco (labs/README.md's
        # node table; confirmed live, Task 7, "Login incorrect" against
        # cisco specifically on this one node).
        out = gen_testbed.patch_device_credentials(self.DEVICES_TEXT, "labrats1")
        host_block = out.split("  kind-host:\n", 1)[1].split("  spine1:\n", 1)[0]
        self.assertIn("username: 'kindops'", host_block)
        self.assertIn("password: 'labrats1'", host_block)

    def test_terminal_server_is_left_untouched(self) -> None:
        out = gen_testbed.patch_device_credentials(self.DEVICES_TEXT, "labrats1")
        proxy_block = out.split("  terminal_server:\n", 1)[1]
        self.assertIn("username: 'admin'", proxy_block)
        self.assertNotIn("labrats1", proxy_block)

    def test_raises_when_no_device_placeholder_found(self) -> None:
        with self.assertRaisesRegex(gen_testbed.TestbedError, "no device cisco/cisco placeholder"):
            gen_testbed.patch_device_credentials("devices:\n  terminal_server:\n    os: linux\n", "labrats1")


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
                "LAB_PASSWORD": "TestLabPassword-DoNotLeak",
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
            self.assertNotIn("TestLabPassword-DoNotLeak", result.stdout)
            self.assertNotIn("TestLabPassword-DoNotLeak", result.stderr)
            self.assertEqual(stat.S_IMODE(out_path.stat().st_mode), 0o600)
            written = out_path.read_text()
            self.assertIn("testbed:", written)
            # Neither placeholder should survive: the terminal_server
            # proxy's change_me, or any real device's cisco/cisco guess.
            # Without both, some device connection fails (caught live,
            # Task 7).
            self.assertNotIn("change_me", written)
            self.assertNotIn("password: cisco\n        username: cisco", written)
            self.assertIn("password: 'TestLabPassword-DoNotLeak'\n        username: 'admin'", written)

    def test_cli_unknown_lab_title_fails_without_writing(self) -> None:
        with tempfile.TemporaryDirectory(prefix=".tmp.gen_testbed.", dir=REPO / "tests") as tmp:
            out_path = Path(tmp) / "testbed.yaml"
            env = dict(os.environ)
            env.update({
                "CML_URL": BASE_URL,
                "CML_USERNAME": "admin",
                "CML_PASSWORD": "secret",
                "CML_VERIFY_SSL": "false",
                "LAB_PASSWORD": "TestLabPassword-DoNotLeak",
            })
            result = subprocess.run(
                [sys.executable, str(REPO / "verify" / "lib" / "gen_testbed.py"), "Nope", str(out_path)],
                env=env, capture_output=True, text=True, timeout=30,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(out_path.exists())
            self.assertNotIn("secret", result.stderr)


class PatchTerminalServerSshOptionsTest(unittest.TestCase):
    """gen_testbed.patch_terminal_server_ssh_options, no server needed."""

    TESTBED = (
        "devices:\n"
        "  edge:\n"
        "    connections:\n"
        "      a:\n"
        "        command: open /lab/edge/0\n"
        "        proxy: terminal_server\n"
        "  terminal_server:\n"
        "    connections:\n"
        "      cli:\n"
        "        ip: 192.0.2.10\n"
        "        port: 22\n"
        "        protocol: ssh\n"
        "    os: linux\n"
    )

    def test_pins_the_console_hop_to_the_given_known_hosts(self) -> None:
        out = gen_testbed.patch_terminal_server_ssh_options(self.TESTBED, Path("/repo/keys/known_hosts"))
        self.assertIn(
            "        protocol: ssh\n"
            "        ssh_options: '-o UserKnownHostsFile=/repo/keys/known_hosts -o StrictHostKeyChecking=accept-new'\n",
            out,
        )

    def test_only_the_terminal_server_block_changes(self) -> None:
        out = gen_testbed.patch_terminal_server_ssh_options(self.TESTBED, Path("/repo/keys/known_hosts"))
        edge_block = out.split("  terminal_server:\n", 1)[0]
        self.assertNotIn("ssh_options", edge_block)
        self.assertEqual(out.count("ssh_options"), 1)

    def test_default_is_the_repo_local_known_hosts(self) -> None:
        self.assertEqual(gen_testbed.KNOWN_HOSTS, REPO / "keys" / "known_hosts")

    def test_raises_when_the_ssh_line_is_absent(self) -> None:
        with self.assertRaises(gen_testbed.TestbedError):
            gen_testbed.patch_terminal_server_ssh_options("devices:\n  terminal_server:\n    os: linux\n")


if __name__ == "__main__":
    unittest.main()
