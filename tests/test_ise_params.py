import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

LIB = Path(__file__).resolve().parent.parent / "scripts" / "lib"
sys.path.insert(0, str(LIB))
import ise_params  # noqa: E402

ENV = {
    "ISE_HOSTNAME": "ise1",
    "ISE_VM_SIZE": "Standard_D8s_v4",
    "ISE_STORAGE_TYPE": "Premium_LRS",
    "ISE_VOLUME_SIZE": "600",
    "ISE_PRIVATE_IP": "10.20.2.20",
    "ISE_PUBLIC_IP_NAME": "ise1-ip",
    "ISE_DNS_DOMAIN": "rooez.com",
    "ISE_PRIMARY_NAMESERVER": "8.8.8.8",
    "ISE_PRIMARY_NTP": "time.google.com",
    "ISE_TIMEZONE": "Etc/UTC",
    "ISE_ERS": "yes",
    "ISE_PXGRID": "yes",
    "ISE_ADMIN_PASSWORD": "Sup3rSecret-Test",
}
PUBKEY = "ssh-rsa AAAATESTKEY test@lab"


class TestIseParams(unittest.TestCase):
    def test_render_maps_values_and_static_ip(self) -> None:
        params = ise_params.render_parameters(ENV, PUBKEY, "ise-nsg")["parameters"]
        self.assertEqual(params["hostName"]["value"], "ise1")
        self.assertEqual(params["managementPrivateIP"]["value"], "10.20.2.20")
        self.assertEqual(params["managementNSG"]["value"], "ise-nsg")
        self.assertEqual(params["SSHKeyPairName"]["value"], PUBKEY)
        self.assertEqual(params["instanceType"]["value"], "Standard_D8s_v4")
        self.assertEqual(params["publicIpNewOrExisting"]["value"], "new")
        self.assertEqual(params["publicIpSku"]["value"], "Standard")
        self.assertEqual(params["publicIpAllocationMethod"]["value"], "Static")
        self.assertEqual(params["primaryNTPServer"]["value"], "time.google.com")
        self.assertEqual(params["systemPassword"]["value"], "Sup3rSecret-Test")

    def test_missing_password_raises(self) -> None:
        env = dict(ENV)
        del env["ISE_ADMIN_PASSWORD"]
        with self.assertRaises(KeyError):
            ise_params.render_parameters(env, PUBKEY, "ise-nsg")

    def test_cli_writes_0600_and_no_secret_on_stdout(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / "params.json"
            pub = Path(d) / "k.pub"
            pub.write_text(PUBKEY)
            env = dict(os.environ)
            env.update(ENV)
            env["ISE_PUBKEY_FILE"] = str(pub)
            proc = subprocess.run(
                [sys.executable, str(LIB / "ise_params.py"), str(out), "--nsg", "ise-nsg"],
                env=env, capture_output=True, text=True, check=True,
            )
            self.assertNotIn("Sup3rSecret-Test", proc.stdout)
            self.assertNotIn("Sup3rSecret-Test", proc.stderr)
            mode = stat.S_IMODE(out.stat().st_mode)
            self.assertEqual(mode, 0o600)
            doc = json.loads(out.read_text())
            self.assertEqual(doc["parameters"]["systemPassword"]["value"], "Sup3rSecret-Test")


if __name__ == "__main__":
    unittest.main()
