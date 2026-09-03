"""Tests for scripts/lib/mcp_call.py against tests/fake_mcp_server.py."""
import subprocess
import sys
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
CLIENT = REPO / "scripts" / "lib" / "mcp_call.py"
FAKE = f"{sys.executable} {REPO / 'tests' / 'fake_mcp_server.py'}"


def call(*extra: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run([sys.executable, str(CLIENT), "--cmd", FAKE, *extra],
                          capture_output=True, text=True, timeout=30)


class McpCallTest(unittest.TestCase):
    def test_calls_tool_and_prints_text(self) -> None:
        proc = call("--tool", "get_cml_labs")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("Spine Leaf", proc.stdout)

    def test_unknown_tool_exits_1(self) -> None:
        proc = call("--tool", "nope")
        self.assertEqual(proc.returncode, 1)
        self.assertIn("nope", proc.stderr)

    def test_dead_command_exits_1(self) -> None:
        proc = subprocess.run([sys.executable, str(CLIENT), "--cmd", "false", "--tool", "x"],
                              capture_output=True, text=True, timeout=30)
        self.assertEqual(proc.returncode, 1)

    def test_tool_error_exits_1(self) -> None:
        proc = call("--tool", "boom")
        self.assertEqual(proc.returncode, 1)
        self.assertIn("boom failed", proc.stderr)


if __name__ == "__main__":
    unittest.main()
