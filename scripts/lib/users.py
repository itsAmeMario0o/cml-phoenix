#!/usr/bin/env python3
"""Create CML users from a CSV and give them every lab on the controller.

    scripts/70-users.sh [--dry-run] [--csv FILE]
    scripts/70-users.sh class NAME COUNT DOMAIN

CSV columns: email,fullname,role. The email is the CML username, since a
person logs in to CML with the same address the Cloudflare Access policy
checks. role is admin or user. A generated password per new user goes to
config/mcp-env/users-credentials.csv, mode 0600, never to stdout.

Every non-admin user is placed in one managed group (LAB_GROUP, default
"lab-users"), and that group is granted a permission (LAB_PERMISSION,
default lab_exec) on every lab currently on the controller. So a user
sees every lab in the kit, and importing a new lab then rerunning this
grants it to everyone. Admins need no grant; CML shows them all labs.

Users and grants that already exist are left as they are, so the same
file can be applied after every rebuild. Controller credentials come
from the environment: CML_URL, CML_USERNAME, CML_PASSWORD,
CML_VERIFY_SSL. Stdlib only. ADR 0007.
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
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

COLUMNS = ["email", "fullname", "role"]
ROLES = {"admin", "user"}
# CML caps a username at 32 characters. Cisco CEC addresses fit; a very
# long address does not, and the API would reject it, so catch it here.
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
USERNAME_MAX = 32
PASSWORD_ALPHABET = string.ascii_letters + string.digits
PASSWORD_LENGTH = 16
DEFAULT_GROUP = "lab-users"
DEFAULT_PERMISSION = "lab_exec"
PERMISSIONS = {"lab_admin", "lab_edit", "lab_exec", "lab_view"}


class UsersError(Exception):
    """Anything that should stop the run with a message and exit 1."""


@dataclass
class Row:
    email: str
    fullname: str
    role: str

    @property
    def username(self) -> str:
        return self.email

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
        if not EMAIL_RE.match(row.email):
            raise UsersError(f"line {n}: {row.email!r} is not an email address")
        if len(row.email) > USERNAME_MAX:
            raise UsersError(f"line {n}: {row.email!r} is {len(row.email)} chars; CML caps a username at {USERNAME_MAX}")
        if row.email.lower() in seen:
            raise UsersError(f"line {n}: duplicate email {row.email!r}")
        if row.role not in ROLES:
            raise UsersError(f"line {n}: role must be admin or user, got {row.role!r}")
        seen.add(row.email.lower())
        rows.append(row)
    if not rows:
        raise UsersError("no user rows in the CSV")
    return rows


def generate_password(length: int = PASSWORD_LENGTH) -> str:
    """Letters and digits only, so it types cleanly and needs no quoting."""
    return "".join(secrets.choice(PASSWORD_ALPHABET) for _ in range(length))


def class_rows(name: str, count: int, domain: str) -> list[str]:
    """CSV lines for a synthetic class: name01@domain .. nameNN@domain, all users."""
    if not re.match(r"^[a-z0-9-]{1,20}$", name) or count < 1 or count > 99:
        raise UsersError("class needs a simple lowercase name and a count from 1 to 99")
    if not EMAIL_RE.match(f"x@{domain}"):
        raise UsersError(f"class needs a domain like cisco.com, got {domain!r}")
    return [f"{name}{i:02d}@{domain},{name.capitalize()} {i:02d},user" for i in range(1, count + 1)]


class CmlApi:
    """The user, group, and lab calls this script needs."""

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

    def lab_ids(self) -> list[str]:
        return list(self._request("GET", "/labs"))

    def create_group(self, name: str) -> str:
        body = {"name": name, "description": "lab access, managed by 70-users.sh", "members": []}
        return self._request("POST", "/groups", body)["id"]

    def update_group(self, group_id: str, members: list[str], associations: list[dict[str, Any]]) -> None:
        self._request("PATCH", f"/groups/{group_id}", {"members": members, "associations": associations})

    def create_user(self, row: Row, password: str, group_id: str) -> str:
        body: dict[str, Any] = {"username": row.username, "password": password, "fullname": row.fullname,
                                "email": row.email, "admin": row.admin,
                                "groups": [] if row.admin or not group_id else [group_id]}
        return self._request("POST", "/users", body)["id"]


@dataclass
class Outcome:
    created: list[tuple[Row, str]] = field(default_factory=list)
    existing: list[Row] = field(default_factory=list)
    group_created: bool = False
    members_added: int = 0
    labs_granted: int = 0


def apply(rows: list[Row], api: CmlApi, group_name: str, permission: str,
          dry_run: bool, log: Any = print) -> Outcome:
    """Create missing users, then give the managed group every lab. Idempotent."""
    if permission not in PERMISSIONS:
        raise UsersError(f"permission must be one of {sorted(PERMISSIONS)}, got {permission!r}")
    existing_users = api.users()
    groups = api.groups()
    outcome = Outcome()

    group = groups.get(group_name)
    if group is None:
        if dry_run:
            log(f"[OK]    would create group {group_name}")
            group = {"id": "", "members": [], "associations": []}
        else:
            gid = api.create_group(group_name)
            group = {"id": gid, "members": [], "associations": []}
            log(f"[OK]    created group {group_name}")
        outcome.group_created = True
    gid = group["id"]

    for row in rows:
        if row.username in existing_users:
            outcome.existing.append(row)
            log(f"[OK]    {row.username} exists, left alone")
            continue
        password = generate_password()
        if dry_run:
            log(f"[OK]    would create {row.username} ({row.role})")
        else:
            uid = api.create_user(row, password, gid)
            existing_users[row.username] = {"id": uid, "admin": row.admin}
            log(f"[OK]    created {row.username} ({row.role})")
        outcome.created.append((row, password))

    # Every non-admin user in the file should be a member. Admins are left
    # out; CML shows an admin all labs already. Union with current members
    # so a member added by hand is not dropped.
    want_members = {existing_users[r.username]["id"] for r in rows
                    if not r.admin and r.username in existing_users}
    members = sorted(set(group.get("members") or []) | want_members)
    outcome.members_added = len(want_members - set(group.get("members") or []))

    lab_ids = api.lab_ids()
    have = {a["id"] for a in (group.get("associations") or [])}
    associations = list(group.get("associations") or [])
    for lab_id in lab_ids:
        if lab_id not in have:
            associations.append({"id": lab_id, "permissions": [permission]})
    outcome.labs_granted = len([lab for lab in lab_ids if lab not in have])

    if dry_run:
        log(f"[OK]    would grant {group_name} {permission} on {len(lab_ids)} lab(s), "
            f"{len(want_members)} member(s)")
    elif gid:
        api.update_group(gid, members, associations)
        log(f"[OK]    {group_name}: {len(members)} member(s), {permission} on {len(lab_ids)} lab(s)")
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
            writer.writerow([row.email, row.fullname, row.role, password])


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
    group_name = os.environ.get("LAB_GROUP", DEFAULT_GROUP)
    permission = os.environ.get("LAB_PERMISSION", DEFAULT_PERMISSION)
    try:
        api = CmlApi(url, os.environ.get("CML_USERNAME", ""), os.environ.get("CML_PASSWORD", ""),
                     env_bool("CML_VERIFY_SSL", True))
        outcome = apply(rows, api, group_name, permission, args.dry_run)
    except UsersError as exc:
        print(f"users: {exc}", file=sys.stderr)
        return 1
    if outcome.created and not args.dry_run:
        write_credentials(Path(args.credentials), outcome.created)
        print(f"[OK]    {len(outcome.created)} password(s) written to {args.credentials}")
    elif not outcome.created:
        print("[OK]    no new users; credentials file untouched")
    print("[OK]    Access policy emails: " + ", ".join(sorted(r.email for r in rows)))
    return 0


def cmd_class(args: argparse.Namespace) -> int:
    try:
        lines = class_rows(args.name, args.count, args.domain)
    except UsersError as exc:
        print(f"users: {exc}", file=sys.stderr)
        return 1
    print(",".join(COLUMNS))
    print("\n".join(lines))
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    p_apply = sub.add_parser("apply", help="create users and grant every lab")
    p_apply.add_argument("--csv", required=True)
    p_apply.add_argument("--credentials", required=True, help="where generated passwords are written")
    p_apply.add_argument("--dry-run", action="store_true")
    p_apply.set_defaults(func=cmd_apply)
    p_class = sub.add_parser("class", help="print CSV rows for a synthetic class")
    p_class.add_argument("name")
    p_class.add_argument("count", type=int)
    p_class.add_argument("domain")
    p_class.set_defaults(func=cmd_class)
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
