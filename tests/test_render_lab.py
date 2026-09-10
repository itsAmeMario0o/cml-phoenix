"""Tests for scripts/lib/render_lab.py and the tracked topologies in labs/."""
import os
import re
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
RENDER = REPO / "scripts" / "lib" / "render_lab.py"
LABS = sorted((REPO / "labs").glob("*.yaml"))

TOPOLOGY = (
    "lab:\n  title: Demo Lab\n  version: 0.1.0\nnodes:\n- id: n0\n  configuration:\n"
    "  - name: nxos_config.txt\n    content: |\n      username admin password __LAB_PASSWORD__\n"
    "  - name: user-data\n    content: |\n      ssh_authorized_keys:\n        - __LAB_SSH_PUBKEY__\n"
)


def run(args: list[str], env: dict[str, str] | None = None) -> subprocess.CompletedProcess:
    full_env = {**os.environ, **(env or {})}
    full_env.pop("LAB_PASSWORD", None)
    if env and "LAB_PASSWORD" in env:
        full_env["LAB_PASSWORD"] = env["LAB_PASSWORD"]
    return subprocess.run([sys.executable, str(RENDER), *args], capture_output=True, text=True, env=full_env)


class RenderLabTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix=".tmp.render_lab.", dir=REPO / "tests"))
        self.topology = self.tmp / "demo.yaml"
        self.topology.write_text(TOPOLOGY)
        self.pubkey = self.tmp / "key.pub"
        self.pubkey.write_text("ssh-ed25519 AAAATESTKEY demo@example\n")

    def tearDown(self) -> None:
        for p in self.tmp.iterdir():
            p.unlink()
        self.tmp.rmdir()

    def test_renders_both_placeholders_to_stdout(self) -> None:
        result = run([str(self.topology), "--pubkey", str(self.pubkey)], {"LAB_PASSWORD": "Sekret1"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("username admin password Sekret1", result.stdout)
        self.assertIn("- ssh-ed25519 AAAATESTKEY demo@example", result.stdout)
        self.assertNotIn("__LAB_", result.stdout)

    def test_output_file_is_private(self) -> None:
        out = self.tmp / "rendered.yaml"
        out.write_text("old")
        os.chmod(out, 0o644)
        result = run([str(self.topology), "--pubkey", str(self.pubkey), "--out", str(out)],
                     {"LAB_PASSWORD": "Sekret1"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(stat.S_IMODE(out.stat().st_mode), 0o600)
        self.assertIn("Sekret1", out.read_text())

    def test_empty_password_fails(self) -> None:
        result = run([str(self.topology), "--pubkey", str(self.pubkey)])
        self.assertEqual(result.returncode, 1)
        self.assertIn("LAB_PASSWORD is empty", result.stderr)

    def test_missing_pubkey_fails(self) -> None:
        result = run([str(self.topology), "--pubkey", str(self.tmp / "nope.pub")], {"LAB_PASSWORD": "x"})
        self.assertEqual(result.returncode, 1)
        self.assertIn("cannot read", result.stderr)

    def test_leftover_placeholder_fails(self) -> None:
        self.topology.write_text(TOPOLOGY + "  - name: extra\n    content: __OTHER_THING__\n")
        result = run([str(self.topology), "--pubkey", str(self.pubkey)], {"LAB_PASSWORD": "x"})
        self.assertEqual(result.returncode, 1)
        self.assertIn("unfilled placeholders: __OTHER_THING__", result.stderr)

    def test_print_title(self) -> None:
        result = run([str(self.topology), "--pubkey", str(self.pubkey), "--print-title"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "Demo Lab")


class TrackedLabsTest(unittest.TestCase):
    """Every topology under labs/ must carry placeholders, never passwords."""

    def test_labs_present(self) -> None:
        self.assertTrue(LABS, "no topologies under labs/")

    def test_no_known_default_passwords(self) -> None:
        for lab in LABS:
            text = lab.read_text()
            for bad in ("C1sco12345", "password: cisco", "password: 'cisco'"):
                self.assertNotIn(bad, text, f"{lab.name} carries a real password")

    def test_password_lines_use_placeholder(self) -> None:
        for lab in LABS:
            for line in lab.read_text().splitlines():
                if re.search(r"^\s*(username \S+ password|password:)", line):
                    self.assertIn("__LAB_PASSWORD__", line, f"{lab.name}: {line.strip()}")

    def test_every_lab_renders(self) -> None:
        with tempfile.TemporaryDirectory(prefix=".tmp.labs.", dir=REPO / "tests") as tmp:
            pubkey = Path(tmp) / "key.pub"
            pubkey.write_text("ssh-ed25519 AAAATESTKEY demo@example\n")
            for lab in LABS:
                result = run([str(lab), "--pubkey", str(pubkey)], {"LAB_PASSWORD": "Sekret1"})
                self.assertEqual(result.returncode, 0, f"{lab.name}: {result.stderr}")
                title = run([str(lab), "--pubkey", str(pubkey), "--print-title"]).stdout.strip()
                self.assertTrue(title, f"{lab.name} has no title")


if __name__ == "__main__":
    unittest.main()
