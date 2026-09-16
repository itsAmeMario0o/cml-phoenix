"""Tests for scripts/lib/ise_config.py: the minimal ISE policy (one
network device, one authorization rule), against tests/fake_ise_api.py.
Create-if-missing, idempotent on rerun, like tests/test_users.py for
scripts/lib/users.py."""
import os
import subprocess
import sys
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts" / "lib"))
import ise_config  # noqa: E402

PORT = 18008


class EnsureNetworkDeviceTest(unittest.TestCase):
    proc: subprocess.Popen

    @classmethod
    def setUpClass(cls) -> None:
        cls.proc = subprocess.Popen([sys.executable, str(REPO / "tests" / "fake_ise_api.py"), str(PORT)])
        for _ in range(50):
            try:
                req = urllib.request.Request(f"http://127.0.0.1:{PORT}/ers/config/networkdevice")
                with urllib.request.urlopen(req, timeout=1):
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

    def setUp(self) -> None:
        self.client = ise_config.IseErsClient(f"http://127.0.0.1:{PORT}", "admin", "secret")

    def test_bad_login(self) -> None:
        bad = ise_config.IseErsClient(f"http://127.0.0.1:{PORT}", "admin", "wrong")
        with self.assertRaisesRegex(ise_config.IseConfigError, "HTTP 401"):
            ise_config.ensure_network_device(bad, "nad-bad-login", "10.100.0.9", "secret123")

    def test_find_missing_device_returns_none(self) -> None:
        self.assertIsNone(ise_config.find_network_device_id(self.client, "not-registered-yet"))

    def test_ensure_creates_when_absent_and_returns_an_id(self) -> None:
        device_id = ise_config.ensure_network_device(self.client, "c8000v-edge-1", "10.100.0.2", "radius-secret-1")
        self.assertTrue(device_id)
        self.assertEqual(ise_config.find_network_device_id(self.client, "c8000v-edge-1"), device_id)

    def test_ensure_is_idempotent_on_rerun(self) -> None:
        first_id = ise_config.ensure_network_device(self.client, "c8000v-edge-2", "10.100.0.2", "radius-secret-2")
        second_id = ise_config.ensure_network_device(self.client, "c8000v-edge-2", "10.100.0.2", "radius-secret-2")
        self.assertEqual(first_id, second_id)

    def test_ensure_does_not_post_when_already_present(self) -> None:
        # A second POST for the same name would 400 in the fake. Ensure
        # ensure_network_device does not attempt one.
        ise_config.ensure_network_device(self.client, "c8000v-edge-3", "10.100.0.2", "radius-secret-3")
        try:
            ise_config.ensure_network_device(self.client, "c8000v-edge-3", "10.100.0.2", "radius-secret-3")
        except ise_config.IseConfigError as exc:
            self.fail(f"rerun should not attempt a create: {exc}")


class EnsureAuthorizationRuleTest(unittest.TestCase):
    """Policy sets and authorization rules live under the ISE OpenAPI on
    real ISE (ADR 0008, Phase 1 review), not ERS, so these tests exercise
    IseOpenApiClient against the fake's OpenAPI endpoints and their
    plain-array response shape."""

    proc: subprocess.Popen

    @classmethod
    def setUpClass(cls) -> None:
        cls.proc = subprocess.Popen([sys.executable, str(REPO / "tests" / "fake_ise_api.py"), str(PORT + 1)])
        for _ in range(50):
            try:
                req = urllib.request.Request(
                    f"http://127.0.0.1:{PORT + 1}/api/v1/policy/network-access/policy-set"
                )
                with urllib.request.urlopen(req, timeout=1):
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

    def setUp(self) -> None:
        self.client = ise_config.IseOpenApiClient(f"http://127.0.0.1:{PORT + 1}", "admin", "secret")

    def test_bad_login(self) -> None:
        bad = ise_config.IseOpenApiClient(f"http://127.0.0.1:{PORT + 1}", "admin", "wrong")
        with self.assertRaisesRegex(ise_config.IseConfigError, "HTTP 401"):
            ise_config.find_policy_set_id(bad, "Default")

    def test_find_policy_set_id_by_name(self) -> None:
        self.assertEqual(ise_config.find_policy_set_id(self.client, "Default"), "ps-default")

    def test_missing_policy_set_raises(self) -> None:
        with self.assertRaisesRegex(ise_config.IseConfigError, "not found"):
            ise_config.find_policy_set_id(self.client, "No Such Set")

    def test_find_missing_rule_returns_none(self) -> None:
        policy_set_id = ise_config.find_policy_set_id(self.client, "Default")
        self.assertIsNone(
            ise_config.find_authorization_rule_id(self.client, policy_set_id, "not-created-yet")
        )

    def test_ensure_creates_when_absent_and_returns_an_id(self) -> None:
        rule_id = ise_config.ensure_authorization_rule(
            self.client, "Default", "trustsec-poc-1", "10.100.0.2", "PermitAccess"
        )
        self.assertTrue(rule_id)
        policy_set_id = ise_config.find_policy_set_id(self.client, "Default")
        self.assertEqual(
            ise_config.find_authorization_rule_id(self.client, policy_set_id, "trustsec-poc-1"),
            rule_id,
        )

    def test_ensure_is_idempotent_on_rerun(self) -> None:
        first_id = ise_config.ensure_authorization_rule(
            self.client, "Default", "trustsec-poc-2", "10.100.0.2", "PermitAccess"
        )
        second_id = ise_config.ensure_authorization_rule(
            self.client, "Default", "trustsec-poc-2", "10.100.0.2", "PermitAccess"
        )
        self.assertEqual(first_id, second_id)

    def test_ensure_does_not_post_when_already_present(self) -> None:
        # A second POST for the same name would 400 in the fake (mirrors
        # test_ensure_does_not_post_when_already_present for the NAD).
        ise_config.ensure_authorization_rule(
            self.client, "Default", "trustsec-poc-3", "10.100.0.2", "PermitAccess"
        )
        try:
            ise_config.ensure_authorization_rule(
                self.client, "Default", "trustsec-poc-3", "10.100.0.2", "PermitAccess"
            )
        except ise_config.IseConfigError as exc:
            self.fail(f"rerun should not attempt a create: {exc}")


class MainEntryPointTest(unittest.TestCase):
    def test_missing_env_exits_1(self) -> None:
        result = subprocess.run(
            [sys.executable, str(REPO / "scripts" / "lib" / "ise_config.py")],
            capture_output=True,
            text=True,
            env={},
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("ISE_PRIVATE_IP", result.stderr)


class MainDefaultAdminUsernameTest(unittest.TestCase):
    """main() must default ISE_ADMIN_USERNAME to iseadmin, the Azure
    Marketplace ISE image's fixed admin account, not the generic "admin"
    guess. A wrong default here 401s every real ERS call even though the
    same password is correct (caught live, first real deploy)."""

    proc: subprocess.Popen
    port = PORT + 2

    @classmethod
    def setUpClass(cls) -> None:
        env = dict(os.environ)
        env["FAKE_ISE_USER"] = "iseadmin"
        cls.proc = subprocess.Popen(
            [sys.executable, str(REPO / "tests" / "fake_ise_api.py"), str(cls.port)], env=env
        )
        for _ in range(50):
            try:
                req = urllib.request.Request(f"http://127.0.0.1:{cls.port}/api/v1/policy/network-access/policy-set")
                with urllib.request.urlopen(req, timeout=1):
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

    def test_default_username_is_iseadmin_not_admin(self) -> None:
        # No ISE_ADMIN_USERNAME set: main() must still authenticate as
        # iseadmin against a fake that only accepts that username.
        env = {
            "ISE_API_BASE": f"http://127.0.0.1:{self.port}",
            "ISE_ADMIN_PASSWORD": "secret",
            "RADIUS_SECRET": "radius-secret",
        }
        result = subprocess.run(
            [sys.executable, str(REPO / "scripts" / "lib" / "ise_config.py")],
            capture_output=True, text=True, env=env,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("network device", result.stdout)
        self.assertIn("authorization rule", result.stdout)


if __name__ == "__main__":
    unittest.main()
