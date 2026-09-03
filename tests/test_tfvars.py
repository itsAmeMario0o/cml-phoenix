"""Tests for scripts/lib/tfvars.py, the HCL-subset parser."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts" / "lib"))
import tfvars  # noqa: E402


class ParseTfvarsTest(unittest.TestCase):
    def test_parses_every_supported_type(self) -> None:
        text = """
        # comment line
        name = "cml"   # trailing comment
        count = 12
        price = -1
        flag = true
        other = false
        cidrs = ["10.0.0.1/32", "10.0.0.2/32"]
        empty = []
        """
        result = tfvars.parse_tfvars(text)
        self.assertEqual(result["name"], "cml")
        self.assertEqual(result["count"], 12)
        self.assertEqual(result["price"], -1)
        self.assertIs(result["flag"], True)
        self.assertIs(result["other"], False)
        self.assertEqual(result["cidrs"], ["10.0.0.1/32", "10.0.0.2/32"])
        self.assertEqual(result["empty"], [])

    def test_rejects_unknown_syntax_with_line_number(self) -> None:
        with self.assertRaises(ValueError) as ctx:
            tfvars.parse_tfvars('a = "ok"\nb = { nested = 1 }\n')
        self.assertIn("line 2", str(ctx.exception))

    def test_string_may_contain_hash(self) -> None:
        result = tfvars.parse_tfvars('token = "abc#def"\n')
        self.assertEqual(result["token"], "abc#def")


if __name__ == "__main__":
    unittest.main()
