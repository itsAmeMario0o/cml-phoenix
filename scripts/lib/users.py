#!/usr/bin/env python3
"""Create CML users and groups from a CSV, generating a password for each.

    scripts/70-users.sh [--dry-run] [--csv FILE]
    scripts/70-users.sh class NAME COUNT [DOMAIN]

CSV columns: username,email,fullname,role,group. role is admin or user.
group is optional and is created when missing. Users that already exist
are left alone, so the same file can be applied after every rebuild.
The passwords of the users created in a run go to
config/mcp-env/users-credentials.csv, mode 0600, never to stdout.

Credentials for the controller come from the environment: CML_URL,
CML_USERNAME, CML_PASSWORD, CML_VERIFY_SSL. Stdlib only. ADR 0007.
"""
from __future__ import annotations

import argparse
import csv
import io
import json
import os
import re
import secrets
import ssl
import string
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any

COLUMNS = ["username", "email", "fullname", "role", "group"]
ROLES = {"admin", "user"}
USERNAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,31}$")
PASSWORD_ALPHABET = string.ascii_letters + string.digits
PASSWORD_LENGTH = 16


class UsersError(Exception):
    """Anything that should stop the run with a message and exit 1."""


@dataclass
class Row:
    username: str
    email: str
    fullname: str
    role: str
    group: str

    @property
    def admin(self) -> bool:
        return self.role == "admin"


def load_rows(text: str) -> list[Row]:
    """Parse the CSV. Blank lines and # comments are skipped. Raises UsersError."""
    lines = [ln for ln in text.splitlines() if ln.strip() and not ln.lstrip().startswith("#")]
    reader = csv.DictReader(io.StringIO("\n".join(lines)))
    if reader.fieldnames is None or [f.strip() for f in reader.fieldnames] != COLUMNS:
        raise UsersError(f"header must be exactly: {','.join(COLUMNS)}")
    rows: list[Row] = []
    seen: set[str] = set()
    for n, raw in enumerate(reader, start=2):
        row = Row(**{k: (raw.get(k) or "").strip() for k in COLUMNS})
        if not USERNAME_RE.match(row.username):
            raise UsersError(f"line {n}: bad username {row.username!r} (letters, digits, _ . -, max 32)")
        if row.username in seen:
            raise UsersError(f"line {n}: duplicate username {row.username!r}")
        if row.role not in ROLES:
            raise UsersError(f"line {n}: role must be admin or user, got {row.role!r}")
        if row.email and "@" not in row.email:
            raise UsersError(f"line {n}: email {row.email!r} has no @")
        seen.add(row.username)
        rows.append(row)
    if not rows:
        raise UsersError("no user rows in the CSV")
    return rows


def generate_password(length: int = PASSWORD_LENGTH) -> str:
    """Letters and digits only, so it types cleanly and needs no quoting."""
    return "".join(secrets.choice(PASSWORD_ALPHABET) for _ in range(length))


def class_rows(name: str, count: int, domain: str = "") -> list[str]:
    """CSV lines for a class: name01..nameNN, all plain users in group name."""
    if not USERNAME_RE.match(name) or count < 1 or count > 99:
        raise UsersError("class needs a simple name and a count from 1 to 99")
    out = []
    for i in range(1, count + 1):
        user = f"{name}{i:02d}"
        email = f"{user}@{domain}" if domain else ""
        out.append(f"{user},{email},{name.capitalize()} {i:02d},user,{name}")
    return out


class CmlApi:
    """The handful of user and group calls this script needs."""

    def __init__(self, url: str, username: str, password: str, verify_ssl: bool = True) -> None:
        self.base = url.rstrip("/") + "/api/v0"
        self.ctx = ssl.create_default_context()
        if not verify_ssl:
            self.ctx.check_hostname = False
            self.ctx.verify_mode = ssl.CERT_NONE
        self.token = ""
        self.token = self._request("POST", "/authenticate", {"username": username, "password": password})
        if not isinstance(self.token, str) or not self.token:
            raise UsersError(f"authentication to {url} failed")

    def _request(self, method: str, path: str, body: Any = None) -> Any:
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.base + path, data=data, method=method)
        req.add_header("Accept", "application/json")
        if data is not None:
            req.add_header("Content-Type", "application/json")
        if self.token:
            req.add_header("Authorization", f"Bearer {self.token}")
        try:
            with urllib.request.urlopen(req, context=self.ctx, timeout=30) as resp:
                raw = resp.read()
        except urllib.error.HTTPError as exc:
            with exc:
                detail = exc.read().decode(errors="replace")[:300]
            raise UsersError(f"{method} {path}: HTTP {exc.code} {detail}") from None
        except urllib.error.URLError as exc:
            raise UsersError(f"{method} {path}: {exc.reason}") from None
        return json.loads(raw) if raw else None

    def users(self) -> dict[str, dict[str, Any]]:
        return {u["username"]: u for u in self._request("GET", "/users")}

    def groups(self) -> dict[str, dict[str, Any]]:
        return {g["name"]: g for g in self._request("GET", "/groups")}

    def create_group(self, name: str) -> str:
        result = self._request("POST", "/groups", {"name": name, "description": "created by 70-users.sh", "members": []})
        return result["id"]

    def create_user(self, row: Row, password: str, group_id: str) -> str:
        body: dict[str, Any] = {"username": row.username, "password": password, "fullname": row.fullname,
                                "email": row.email, "admin": row.admin, "groups": [group_id] if group_id else []}
        result = self._request("POST", "/users", body)
        return result["id"]


@dataclass
class Outcome:
    created: list[tuple[Row, str]]
    existing: list[Row]
    groups_created: list[str]


def apply(rows: list[Row], api: CmlApi, dry_run: bool, log: Any = print) -> Outcome:
    """Create what is missing. Never changes a user that already exists."""
    existing_users = api.users()
    groups = api.groups()
    outcome = Outcome([], [], [])
    for name in sorted({r.group for r in rows if r.group} - set(groups)):
        if dry_run:
            log(f"[OK]    would create group {name}")
            groups[name] = {"id": ""}
        else:
            groups[name] = {"id": api.create_group(name)}
            log(f"[OK]    created group {name}")
        outcome.groups_created.append(name)
    for row in rows:
        if row.username in existing_users:
            outcome.existing.append(row)
            log(f"[OK]    {row.username} exists, left alone")
            continue
        group_id = groups[row.group]["id"] if row.group else ""
        password = generate_password()
        if dry_run:
            log(f"[OK]    would create {row.username} ({row.role}{', group ' + row.group if row.group else ''})")
        else:
            api.create_user(row, password, group_id)
            log(f"[OK]    created {row.username} ({row.role}{', group ' + row.group if row.group else ''})")
        outcome.created.append((row, password))
    return outcome


def write_credentials(path: Path, created: list[tuple[Row, str]]) -> None:
    """Overwrite the sheet with this run's users, mode 0600 from the first byte."""
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        path.unlink()
    except FileNotFoundError:
        pass
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", newline="") as handle:
        writer = csv.writer(handle, lineterminator="\n")
        writer.writerow(COLUMNS + ["password"])
        for row, password in created:
            writer.writerow([row.username, row.email, row.fullname, row.role, row.group, password])


def env_bool(name: str, default: bool) -> bool:
    value = os.environ.get(name, "").strip().lower()
    return default if value == "" else value not in {"false", "0", "no"}


def cmd_apply(args: argparse.Namespace) -> int:
    try:
        rows = load_rows(Path(args.csv).read_text())
    except OSError as exc:
        print(f"users: cannot read {args.csv}: {exc}", file=sys.stderr)
        return 1
    except UsersError as exc:
        print(f"users: {args.csv}: {exc}", file=sys.stderr)
        return 1
    url = os.environ.get("CML_URL", "")
    if not url:
        print("users: CML_URL is not set; source config/mcp-env/cml.env", file=sys.stderr)
        return 1
    try:
        api = CmlApi(url, os.environ.get("CML_USERNAME", ""), os.environ.get("CML_PASSWORD", ""),
                     env_bool("CML_VERIFY_SSL", True))
        outcome = apply(rows, api, args.dry_run)
    except UsersError as exc:
        print(f"users: {exc}", file=sys.stderr)
        return 1
    if outcome.created and not args.dry_run:
        write_credentials(Path(args.credentials), outcome.created)
        print(f"[OK]    {len(outcome.created)} password(s) written to {args.credentials}")
    elif not outcome.created:
        print("[OK]    nothing to create; credentials file untouched")
    emails = sorted({r.email for r in rows if r.email})
    if emails:
        print("[OK]    Access policy emails: " + ", ".join(emails))
    missing = [r.username for r in rows if not r.email]
    if missing:
        print(f"[WARN]  no email for {', '.join(missing)}; they cannot pass the Access login until one is in the policy")
    return 0


def cmd_class(args: argparse.Namespace) -> int:
    try:
        lines = class_rows(args.name, args.count, args.domain or "")
    except UsersError as exc:
        print(f"users: {exc}", file=sys.stderr)
        return 1
    print(",".join(COLUMNS))
    print("\n".join(lines))
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    p_apply = sub.add_parser("apply", help="create users and groups from the CSV")
    p_apply.add_argument("--csv", required=True)
    p_apply.add_argument("--credentials", required=True, help="where generated passwords are written")
    p_apply.add_argument("--dry-run", action="store_true")
    p_apply.set_defaults(func=cmd_apply)
    p_class = sub.add_parser("class", help="print CSV rows for a class of students")
    p_class.add_argument("name")
    p_class.add_argument("count", type=int)
    p_class.add_argument("domain", nargs="?", default="")
    p_class.set_defaults(func=cmd_class)
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
