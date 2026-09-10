"""Tests for scripts/lib/users.py: CSV parsing, passwords, class rows, and
the apply flow against tests/fake_cml_api.py."""
import csv
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
sys.path.insert(0, str(REPO / "scripts" / "lib"))
import users  # noqa: E402

PORT = 18006
CSV_TEXT = (
    "# comment\n"
    "username,email,fullname,role,group\n"
    "jdoe,jdoe@example.com,Jane Doe,admin,\n"
    "student01,student01@example.com,Netsec 01,user,netsec\n"
    "\n"
    "student02,,Netsec 02,user,netsec\n"
)


class LoadRowsTest(unittest.TestCase):
    def test_parses_rows_and_skips_comments(self) -> None:
        rows = users.load_rows(CSV_TEXT)
        self.assertEqual([r.username for r in rows], ["jdoe", "student01", "student02"])
        self.assertTrue(rows[0].admin)
        self.assertFalse(rows[1].admin)
        self.assertEqual(rows[1].group, "netsec")
        self.assertEqual(rows[2].email, "")

    def test_bad_header(self) -> None:
        with self.assertRaisesRegex(users.UsersError, "header must be exactly"):
            users.load_rows("user,email\njdoe,x@y\n")

    def test_bad_role(self) -> None:
        with self.assertRaisesRegex(users.UsersError, "line 2: role"):
            users.load_rows("username,email,fullname,role,group\njdoe,,J,root,\n")

    def test_bad_username(self) -> None:
        with self.assertRaisesRegex(users.UsersError, "bad username"):
            users.load_rows("username,email,fullname,role,group\njane doe,,J,user,\n")

    def test_duplicate_username(self) -> None:
        with self.assertRaisesRegex(users.UsersError, "duplicate username"):
            users.load_rows("username,email,fullname,role,group\na,,A,user,\na,,A,user,\n")

    def test_email_without_at(self) -> None:
        with self.assertRaisesRegex(users.UsersError, "has no @"):
            users.load_rows("username,email,fullname,role,group\na,nope,A,user,\n")

    def test_empty(self) -> None:
        with self.assertRaisesRegex(users.UsersError, "no user rows"):
            users.load_rows("username,email,fullname,role,group\n")


class PasswordAndClassTest(unittest.TestCase):
    def test_password_shape(self) -> None:
        seen = {users.generate_password() for _ in range(20)}
        self.assertEqual(len(seen), 20)
        for p in seen:
            self.assertEqual(len(p), 16)
            self.assertTrue(p.isalnum())

    def test_class_rows(self) -> None:
        rows = users.class_rows("netsec", 3, "example.com")
        self.assertEqual(rows[0], "netsec01,netsec01@example.com,Netsec 01,user,netsec")
        self.assertEqual(rows[2], "netsec03,netsec03@example.com,Netsec 03,user,netsec")
        self.assertEqual(users.class_rows("lab", 1)[0], "lab01,,Lab 01,user,lab")
        for row in users.class_rows("netsec", 10):
            users.load_rows("username,email,fullname,role,group\n" + row + "\n")

    def test_class_limits(self) -> None:
        with self.assertRaises(users.UsersError):
            users.class_rows("net sec", 3)
        with self.assertRaises(users.UsersError):
            users.class_rows("netsec", 0)


class ApplyAgainstFakeApiTest(unittest.TestCase):
    proc: subprocess.Popen

    @classmethod
    def setUpClass(cls) -> None:
        cls.proc = subprocess.Popen([sys.executable, str(REPO / "tests" / "fake_cml_api.py"), str(PORT)])
        for _ in range(50):
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{PORT}/api/v0/labs", timeout=1):
                    pass
                break
            except urllib.error.HTTPError as exc:  # 401 means the server is up
                exc.close()
                break
            except OSError:
                time.sleep(0.1)

    @classmethod
    def tearDownClass(cls) -> None:
        cls.proc.terminate()
        cls.proc.wait(timeout=5)

    def setUp(self) -> None:
        self.api = users.CmlApi(f"http://127.0.0.1:{PORT}", "admin", "secret")
        self.rows = users.load_rows(CSV_TEXT)
        self.log: list[str] = []

    def test_bad_login(self) -> None:
        with self.assertRaisesRegex(users.UsersError, "HTTP 403"):
            users.CmlApi(f"http://127.0.0.1:{PORT}", "admin", "wrong")

    def test_dry_run_then_apply_then_idempotent(self) -> None:
        outcome = users.apply(self.rows, self.api, dry_run=True, log=self.log.append)
        self.assertEqual(len(outcome.created), 3)
        self.assertEqual(outcome.groups_created, ["netsec"])
        self.assertEqual(set(self.api.users()), {"admin"}, "dry run must not create")
        self.assertEqual(self.api.groups(), {})

        outcome = users.apply(self.rows, self.api, dry_run=False, log=self.log.append)
        self.assertEqual([r.username for r, _ in outcome.created], ["jdoe", "student01", "student02"])
        live = self.api.users()
        self.assertTrue(live["jdoe"]["admin"])
        self.assertFalse(live["student01"]["admin"])
        group = self.api.groups()["netsec"]
        self.assertEqual(live["student01"]["groups"], [group["id"]])
        self.assertEqual(live["jdoe"]["groups"], [])
        self.assertEqual(len(group["members"]), 2)
        for row, password in outcome.created:
            users.CmlApi(f"http://127.0.0.1:{PORT}", row.username, password)

        again = users.apply(self.rows, self.api, dry_run=False, log=self.log.append)
        self.assertEqual(again.created, [])
        self.assertEqual(len(again.existing), 3)
        self.assertEqual(again.groups_created, [])
        self.assertIn("[OK]    jdoe exists, left alone", self.log)

    def test_write_credentials_private(self) -> None:
        with tempfile.TemporaryDirectory(prefix=".tmp.users.", dir=REPO / "tests") as tmp:
            path = Path(tmp) / "creds.csv"
            path.write_text("old")
            os.chmod(path, 0o644)
            users.write_credentials(path, [(self.rows[0], "Pw1"), (self.rows[1], "Pw2")])
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            with path.open(newline="") as handle:
                sheet = list(csv.DictReader(handle))
            self.assertEqual([r["username"] for r in sheet], ["jdoe", "student01"])
            self.assertEqual(sheet[1]["password"], "Pw2")
            self.assertEqual(sheet[1]["group"], "netsec")


if __name__ == "__main__":
    unittest.main()
