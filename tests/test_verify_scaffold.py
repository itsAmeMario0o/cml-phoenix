import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


class TestVerifyScaffold(unittest.TestCase):
    def test_requirements_pins_pyats(self) -> None:
        req = (ROOT / "verify" / "requirements.txt").read_text()
        self.assertRegex(req, r"(?im)^pyats(\[[a-z]+\])?==")

    def test_venv_and_testbed_gitignored(self) -> None:
        for path in ("verify/.venv/x", "verify/.testbed/x"):
            rc = subprocess.run(["git", "check-ignore", path], cwd=ROOT).returncode
            self.assertEqual(rc, 0, path)


if __name__ == "__main__":
    unittest.main()
