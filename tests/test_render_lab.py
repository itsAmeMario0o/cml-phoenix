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
PLACEHOLDER = re.compile(r"__([A-Z][A-Z0-9_]*)__")

TOPOLOGY = (
    "lab:\n  title: Demo Lab\n  version: 0.1.0\nnodes:\n- id: n0\n  configuration:\n"
    "  - name: nxos_config.txt\n    content: |\n      username admin password __LAB_PASSWORD__\n"
    "  - name: user-data\n    content: |\n      ssh_authorized_keys:\n        - __LAB_SSH_PUBKEY__\n"
)


def run(args: list[str], env: dict[str, str] | None = None) -> subprocess.CompletedProcess:
    full_env = {k: v for k, v in os.environ.items() if not PLACEHOLDER.fullmatch(f"__{k}__")}
    full_env.update(env or {})
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
        result = run([str(self.topology), "--pubkey", str(self.pubkey)], {"LAB_PASSWORD": ""})
        self.assertEqual(result.returncode, 1)
        self.assertIn("missing or empty: LAB_PASSWORD", result.stderr)

    def test_missing_pubkey_fails(self) -> None:
        result = run([str(self.topology), "--pubkey", str(self.tmp / "nope.pub")], {"LAB_PASSWORD": "x"})
        self.assertEqual(result.returncode, 1)
        self.assertIn("cannot read", result.stderr)

    def test_any_placeholder_comes_from_its_variable(self) -> None:
        self.topology.write_text(TOPOLOGY + "  - name: day0\n    content: '__CDFMC_HOST__'\n")
        result = run([str(self.topology), "--pubkey", str(self.pubkey)], {"LAB_PASSWORD": "x"})
        self.assertEqual(result.returncode, 1)
        self.assertIn("missing or empty: CDFMC_HOST", result.stderr)
        result = run([str(self.topology), "--pubkey", str(self.pubkey)],
                     {"LAB_PASSWORD": "x", "CDFMC_HOST": "tenant.example"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("content: 'tenant.example'", result.stdout)

    def test_print_title(self) -> None:
        result = run([str(self.topology), "--pubkey", str(self.pubkey), "--print-title"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "Demo Lab")


class TrackedLabsTest(unittest.TestCase):
    """Every topology under labs/ must carry placeholders, never passwords."""

    PASSWORD_LINE = re.compile(r"^\s*(username \S+ (password|privilege \d+ secret|secret)|password:|\"AdminPassword\":)")

    def test_labs_present(self) -> None:
        self.assertTrue(LABS, "no topologies under labs/")

    def test_no_known_default_passwords(self) -> None:
        for lab in LABS:
            text = lab.read_text()
            for bad in ("C1sco12345", "Cisc01@3", "password: cisco", "password: 'cisco'"):
                self.assertNotIn(bad, text, f"{lab.name} carries a real password")

    def test_password_lines_use_placeholder(self) -> None:
        for lab in LABS:
            for line in lab.read_text().splitlines():
                if self.PASSWORD_LINE.search(line):
                    self.assertIn("__LAB_PASSWORD__", line, f"{lab.name}: {line.strip()}")

    def test_placeholders_are_documented(self) -> None:
        """A stray __WORD__ in a comment would block the import, so every
        placeholder must be a key in config/labs.env.example."""
        example = REPO / "config" / "labs.env.example"
        keys = {ln.split("=", 1)[0] for ln in example.read_text().splitlines() if re.match(r"^[A-Z0-9_]+=", ln)}
        for lab in LABS:
            names = set(PLACEHOLDER.findall(lab.read_text())) - {"LAB_SSH_PUBKEY"}
            self.assertTrue(names <= keys, f"{lab.name}: undocumented placeholders {sorted(names - keys)}")

    def test_every_lab_renders(self) -> None:
        with tempfile.TemporaryDirectory(prefix=".tmp.labs.", dir=REPO / "tests") as tmp:
            pubkey = Path(tmp) / "key.pub"
            pubkey.write_text("ssh-ed25519 AAAATESTKEY demo@example\n")
            for lab in LABS:
                names = set(PLACEHOLDER.findall(lab.read_text())) - {"LAB_SSH_PUBKEY"}
                self.assertIn("LAB_PASSWORD", names, f"{lab.name} has no password placeholder")
                env = {n: f"value-for-{n.lower()}" for n in names}
                result = run([str(lab), "--pubkey", str(pubkey)], env)
                self.assertEqual(result.returncode, 0, f"{lab.name}: {result.stderr}")
                self.assertFalse(PLACEHOLDER.search(result.stdout), f"{lab.name}: placeholder left after render")
                title = run([str(lab), "--pubkey", str(pubkey), "--print-title"]).stdout.strip()
                self.assertTrue(title, f"{lab.name} has no title")


if __name__ == "__main__":
    unittest.main()
