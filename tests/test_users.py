"""Tests for scripts/lib/users.py: CSV parsing, passwords, class rows, and
the apply flow (users, one managed group, every lab) against the fake API."""
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
    "email,fullname,role\n"
    "jdoe@example.com,Jane Doe,admin\n"
    "astudent@example.com,A Student,user\n"
    "\n"
    "bstudent@example.com,B Student,user\n"
)


class LoadRowsTest(unittest.TestCase):
    def test_parses_rows_and_skips_comments(self) -> None:
        rows = users.load_rows(CSV_TEXT)
        self.assertEqual([r.email for r in rows], ["jdoe@example.com", "astudent@example.com", "bstudent@example.com"])
        self.assertTrue(rows[0].admin)
        self.assertFalse(rows[1].admin)
        self.assertEqual(rows[1].username, "astudent@example.com")

    def test_bad_header(self) -> None:
        with self.assertRaisesRegex(users.UsersError, "header must be exactly"):
            users.load_rows("user,email\njdoe,x@y\n")

    def test_bad_role(self) -> None:
        with self.assertRaisesRegex(users.UsersError, "line 2: role"):
            users.load_rows("email,fullname,role\na@b.com,A,root\n")

    def test_not_an_email(self) -> None:
        with self.assertRaisesRegex(users.UsersError, "not an email"):
            users.load_rows("email,fullname,role\njdoe,J,user\n")

    def test_email_too_long(self) -> None:
        long = "a" * 30 + "@cisco.com"
        with self.assertRaisesRegex(users.UsersError, "caps a username at 32"):
            users.load_rows(f"email,fullname,role\n{long},A,user\n")

    def test_duplicate_email(self) -> None:
        with self.assertRaisesRegex(users.UsersError, "duplicate email"):
            users.load_rows("email,fullname,role\na@b.com,A,user\nA@B.com,A,user\n")

    def test_empty(self) -> None:
        with self.assertRaisesRegex(users.UsersError, "no user rows"):
            users.load_rows("email,fullname,role\n")


class PasswordAndClassTest(unittest.TestCase):
    def test_password_shape(self) -> None:
        seen = {users.generate_password() for _ in range(20)}
        self.assertEqual(len(seen), 20)
        for p in seen:
            self.assertEqual(len(p), 16)
            self.assertTrue(p.isalnum())

    def test_class_rows(self) -> None:
        rows = users.class_rows("netsec", 3, "cisco.com")
        self.assertEqual(rows[0], "netsec01@cisco.com,Netsec 01,user")
        self.assertEqual(rows[2], "netsec03@cisco.com,Netsec 03,user")
        for row in users.class_rows("netsec", 10, "cisco.com"):
            users.load_rows("email,fullname,role\n" + row + "\n")

    def test_class_needs_domain(self) -> None:
        with self.assertRaises(users.UsersError):
            users.class_rows("netsec", 3, "notadomain")
        with self.assertRaises(users.UsersError):
            users.class_rows("netsec", 0, "cisco.com")


def _start_fake(port: int, env: dict[str, str]) -> subprocess.Popen:
    proc = subprocess.Popen([sys.executable, str(REPO / "tests" / "fake_cml_api.py"), str(port)],
                            env={**os.environ, **env})
    for _ in range(50):
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/v0/labs", timeout=1):
                pass
            break
        except urllib.error.HTTPError:
            break
        except OSError:
            time.sleep(0.1)
    return proc


def _sheet_rows(path: Path) -> list[dict[str, str]]:
    with path.open(newline="") as handle:
        return list(csv.DictReader(handle))


class ApplyAgainstFakeApiTest(unittest.TestCase):
    proc: subprocess.Popen

    @classmethod
    def setUpClass(cls) -> None:
        cls.proc = _start_fake(PORT, {})

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

    def test_bad_permission(self) -> None:
        with self.assertRaisesRegex(users.UsersError, "permission must be"):
            users.apply(self.rows, self.api, "lab-users", "root", dry_run=True, log=self.log.append)

    def test_dry_run_then_apply_then_idempotent(self) -> None:
        outcome = users.apply(self.rows, self.api, "lab-users", "lab_exec", dry_run=True, log=self.log.append)
        self.assertEqual(len(outcome.created), 3)
        self.assertTrue(outcome.group_created)
        self.assertEqual(set(self.api.users()), {"admin"}, "dry run must not create")
        self.assertEqual(self.api.groups(), {})

        outcome = users.apply(self.rows, self.api, "lab-users", "lab_exec", dry_run=False, log=self.log.append)
        self.assertEqual([r.email for r, _ in outcome.created],
                         ["jdoe@example.com", "astudent@example.com", "bstudent@example.com"])
        live = self.api.users()
        self.assertTrue(live["jdoe@example.com"]["admin"])
        self.assertFalse(live["astudent@example.com"]["admin"])
        group = self.api.groups()["lab-users"]
        # both students are members, the admin is not
        self.assertEqual(len(group["members"]), 2)
        self.assertIn(live["astudent@example.com"]["id"], group["members"])
        self.assertNotIn(live["jdoe@example.com"]["id"], group["members"])
        # the group holds one association per lab the fake serves (3)
        self.assertEqual(len(group["associations"]), 3)
        self.assertEqual({p for a in group["associations"] for p in a["permissions"]}, {"lab_exec"})
        for row, password in outcome.created:
            users.CmlApi(f"http://127.0.0.1:{PORT}", row.email, password)

        again = users.apply(self.rows, self.api, "lab-users", "lab_exec", dry_run=False, log=self.log.append)
        self.assertEqual(again.created, [])
        self.assertEqual(len(again.existing), 3)
        self.assertFalse(again.group_created)
        self.assertEqual(again.labs_granted, 0)
        self.assertIn("[OK]    jdoe@example.com exists, left alone", self.log)

    def test_shared_password_used_for_all(self) -> None:
        # Unique emails so this test does not depend on which other tests
        # have already created users on the shared fake server.
        rows = users.load_rows("email,fullname,role\n"
                               "shareda@example.com,Shared A,user\n"
                               "sharedb@example.com,Shared B,user\n")
        outcome = users.apply(rows, self.api, "lab-users", "lab_exec",
                              dry_run=False, log=self.log.append, shared_password="labpass1")
        self.assertEqual({r.email for r, _ in outcome.created}, {"shareda@example.com", "sharedb@example.com"})
        self.assertEqual({pw for _, pw in outcome.created}, {"labpass1"})
        for row, _ in outcome.created:
            users.CmlApi(f"http://127.0.0.1:{PORT}", row.email, "labpass1")

    def test_short_shared_password_refused(self) -> None:
        with self.assertRaisesRegex(users.UsersError, "at least 8 characters"):
            users.apply(self.rows, self.api, "lab-users", "lab_exec",
                        dry_run=True, log=self.log.append, shared_password="short")

    def test_sheet_new_file_is_private_and_untouched_without_rows(self) -> None:
        with tempfile.TemporaryDirectory(prefix=".tmp.users.", dir=REPO / "tests") as tmp:
            path = Path(tmp) / "creds.csv"
            sheet = users.CredentialSheet(path)
            sheet.close()
            self.assertFalse(path.exists(), "no row, no file")
            sheet = users.CredentialSheet(path)
            sheet.add(self.rows[0], "Pw1")
            sheet.add(self.rows[1], "Pw2")
            sheet.close()
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            rows = _sheet_rows(path)
            self.assertEqual([r["email"] for r in rows], ["jdoe@example.com", "astudent@example.com"])
            self.assertEqual(rows[1]["password"], "Pw2")
            self.assertEqual(rows[1]["role"], "user")

    def test_sheet_existing_wider_file_is_tightened_and_kept(self) -> None:
        with tempfile.TemporaryDirectory(prefix=".tmp.users.", dir=REPO / "tests") as tmp:
            path = Path(tmp) / "creds.csv"
            path.write_text("email,fullname,role,password\nold@example.com,Old,user,OldPw\n")
            os.chmod(path, 0o644)
            sheet = users.CredentialSheet(path)
            sheet.add(self.rows[0], "Pw1")
            sheet.close()
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual([r["password"] for r in _sheet_rows(path)], ["OldPw", "Pw1"])

    def test_second_run_appends_new_user_and_keeps_earlier_rows(self) -> None:
        first = users.load_rows("email,fullname,role\n"
                                "appenda@example.com,Append A,user\n"
                                "appendb@example.com,Append B,user\n")
        second = users.load_rows("email,fullname,role\n"
                                 "appenda@example.com,Append A,user\n"
                                 "appendb@example.com,Append B,user\n"
                                 "appendc@example.com,Append C,user\n")
        with tempfile.TemporaryDirectory(prefix=".tmp.users.", dir=REPO / "tests") as tmp:
            path = Path(tmp) / "creds.csv"
            for rows in (first, second):
                sheet = users.CredentialSheet(path)
                users.apply(rows, self.api, "lab-users", "lab_exec", dry_run=False,
                            log=self.log.append, on_created=sheet.add)
                sheet.close()
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            rows_out = _sheet_rows(path)
            self.assertEqual([r["email"] for r in rows_out],
                             ["appenda@example.com", "appendb@example.com", "appendc@example.com"])
            for r in rows_out:
                users.CmlApi(f"http://127.0.0.1:{PORT}", r["email"], r["password"])


class FailingCreateTest(unittest.TestCase):
    """A separate fake, started with the failure knob, so the third user's
    create fails after the first two have already been made in CML."""
    proc: subprocess.Popen

    @classmethod
    def setUpClass(cls) -> None:
        cls.proc = _start_fake(PORT + 1, {"FAKE_USER_CREATE_FAILS": "failc@example.com"})

    @classmethod
    def tearDownClass(cls) -> None:
        cls.proc.terminate()
        cls.proc.wait(timeout=5)

    def test_failure_on_third_user_keeps_first_two_passwords(self) -> None:
        api = users.CmlApi(f"http://127.0.0.1:{PORT + 1}", "admin", "secret")
        rows = users.load_rows("email,fullname,role\n"
                               "faila@example.com,Fail A,user\n"
                               "failb@example.com,Fail B,user\n"
                               "failc@example.com,Fail C,user\n"
                               "faild@example.com,Fail D,user\n")
        with tempfile.TemporaryDirectory(prefix=".tmp.users.", dir=REPO / "tests") as tmp:
            path = Path(tmp) / "creds.csv"
            sheet = users.CredentialSheet(path)
            with self.assertRaisesRegex(users.UsersError, "HTTP 500"):
                users.apply(rows, api, "lab-users", "lab_exec", dry_run=False,
                            log=[].append, on_created=sheet.add)
            # The rows are on disk before close: they were flushed per user.
            rows_out = _sheet_rows(path)
            sheet.close()
            self.assertEqual(sheet.count, 2)
            self.assertEqual([r["email"] for r in rows_out], ["faila@example.com", "failb@example.com"])
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(set(api.users()) - {"admin"}, {"faila@example.com", "failb@example.com"})
            for r in rows_out:
                users.CmlApi(f"http://127.0.0.1:{PORT + 1}", r["email"], r["password"])


if __name__ == "__main__":
    unittest.main()
