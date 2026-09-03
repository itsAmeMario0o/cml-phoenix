"""Tests for scripts/lib/render_cml_config.py."""
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
RENDER = REPO / "scripts" / "lib" / "render_cml_config.py"
TEMPLATE = REPO / "config" / "cml.yml.tftpl"

SETS = {
    "RESOURCE_GROUP": "rg-cml-lab", "STORAGE_ACCOUNT": "stcmllababc123",
    "CONTAINER_NAME": "cml", "VNET_NAME": "vnet-cml-lab", "SUBNET_NAME": "snet-cml",
    "PRIVATE_IP": "10.20.1.10", "PUBLIC_IP_NAME": "pip-cml-lab",
    "DATA_DISK_ID": "/subscriptions/x/resourceGroups/rg-cml-lab/providers/Microsoft.Compute/disks/disk-cml-lab-data",
    "OS_DISK_TYPE": "Premium_LRS", "APPS_SUBNET_CIDR": "10.20.2.0/24",
    "LAB_SUMMARY_CIDR": "10.100.0.0/16", "SSH_KEY_NAME": "sshkey-cml-lab",
    "APP_PASSWORD": "AppPass1234567890", "SYS_PASSWORD": "SysPass1234567890",
}

TFVARS = '''
smartlicense_token = "TOKENVALUE"
license_flavor = "CML_Personal"
allowed_ipv4_subnets_mgmt = ["203.0.113.10/32"]
allowed_ipv4_subnets_cml2 = ["203.0.113.10/32", "203.0.113.11/32"]
vm_size = "Standard_E16ds_v5"
os_disk_size_gb = 200
spot_enabled = false
spot_max_bid_price = -1
sas_validity = "4h"
software_package = "cml2_2.9.0-3_amd64-3.pkg"
'''

REFPLAT = "# def image\nalpine alpine-base-3-21-3\niosv iosv-159-3-m10\n"


class RenderTest(unittest.TestCase):
    def setUp(self) -> None:
        tmp_root = REPO / "tests"
        self.tmp = Path(tempfile.mkdtemp(prefix=".tmp.", dir=tmp_root))
        (self.tmp / "cml.tfvars").write_text(TFVARS)
        (self.tmp / "refplat.txt").write_text(REFPLAT)

    def tearDown(self) -> None:
        for p in self.tmp.iterdir():
            p.unlink()
        self.tmp.rmdir()

    def run_render(self, tfvars_text: str | None = None, sets: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
        if tfvars_text is not None:
            (self.tmp / "cml.tfvars").write_text(tfvars_text)
        cmd = [sys.executable, str(RENDER), "--template", str(TEMPLATE),
               "--tfvars", str(self.tmp / "cml.tfvars"), "--refplat", str(self.tmp / "refplat.txt"),
               "--out", str(self.tmp / "cml.yml")]
        for k, v in (sets if sets is not None else SETS).items():
            cmd += ["--set", f"{k}={v}"]
        return subprocess.run(cmd, capture_output=True, text=True)

    def test_renders_complete_yaml(self) -> None:
        proc = self.run_render()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        out = (self.tmp / "cml.yml").read_text()
        self.assertNotIn("${", out)
        self.assertIn("target: azure", out)
        self.assertIn("size: Standard_E16ds_v5", out)
        self.assertIn('allowed_ipv4_subnets_cml2: ["203.0.113.10/32", "203.0.113.11/32"]', out)
        self.assertIn("    - alpine-base-3-21-3", out)
        self.assertIn("    - iosv\n", out)
        self.assertIn('raw_secret: "TOKENVALUE"', out)
        self.assertIn("software: cml2_2.9.0-3_amd64-3.pkg", out)
        self.assertIn("enabled: false", out)
        mode = oct(os.stat(self.tmp / "cml.yml").st_mode & 0o777)
        self.assertEqual(mode, "0o600")

    def test_refuses_open_cidr(self) -> None:
        proc = self.run_render(TFVARS.replace('"203.0.113.10/32"]', '"0.0.0.0/0"]', 1))
        self.assertEqual(proc.returncode, 1)
        self.assertIn("0.0.0.0/0", proc.stderr)

    def test_reports_missing_placeholders(self) -> None:
        sets = dict(SETS)
        del sets["DATA_DISK_ID"]
        proc = self.run_render(sets=sets)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("DATA_DISK_ID", proc.stderr)

    def test_token_with_colon_renders_quoted(self) -> None:
        proc = self.run_render(TFVARS.replace('"TOKENVALUE"', '"AB: CD"'))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        out = (self.tmp / "cml.yml").read_text()
        self.assertIn('raw_secret: "AB: CD"', out)

    def test_token_with_double_quote_is_refused(self) -> None:
        proc = self.run_render(TFVARS.replace('"TOKENVALUE"', '"AB\\"CD"'))
        self.assertEqual(proc.returncode, 1)
        self.assertIn("smartlicense_token", proc.stderr)

    def test_passwords_from_environment(self) -> None:
        sets = dict(SETS)
        del sets["APP_PASSWORD"]
        del sets["SYS_PASSWORD"]
        cmd = [sys.executable, str(RENDER), "--template", str(TEMPLATE),
               "--tfvars", str(self.tmp / "cml.tfvars"), "--refplat", str(self.tmp / "refplat.txt"),
               "--out", str(self.tmp / "cml.yml")]
        for k, v in sets.items():
            cmd += ["--set", f"{k}={v}"]
        env = dict(os.environ)
        env["APP_PASSWORD"] = SETS["APP_PASSWORD"]
        env["SYS_PASSWORD"] = SETS["SYS_PASSWORD"]
        proc = subprocess.run(cmd, capture_output=True, text=True, env=env)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        out = (self.tmp / "cml.yml").read_text()
        self.assertIn('raw_secret: "AppPass1234567890"', out)


if __name__ == "__main__":
    unittest.main()
