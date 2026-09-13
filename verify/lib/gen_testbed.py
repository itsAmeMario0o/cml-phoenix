#!/usr/bin/env python3
"""Fetch a pyATS testbed for a running CML lab, by title, over the CML API.

Task 2 of the pyATS lab-verification layer (ADR 0009). This generator is
stdlib only and deliberately separate from the pyATS venv described in
verify/README.md: the venv exists to run AEtest scripts, and fetching a
testbed from the controller needs nothing pyATS provides. Keeping it
stdlib also means it stays covered by tests/run.sh, which does not require
pyATS to be installed.

Controller credentials come only from the environment (CML_URL,
CML_USERNAME, CML_PASSWORD, CML_VERIFY_SSL), the same gitignored env file
the rest of the kit reads (config/mcp-env/cml.env, ADR 0004). They are
never taken from argv, where they would show up in `ps` and shell
history, and are never printed. The fetched testbed can itself carry
device credentials for console access, so the CLI writes it private from
the first byte and reports only the path it wrote.

    python3 verify/lib/gen_testbed.py <lab_title> <out_file>
"""
from __future__ import annotations

import json
import os
import ssl
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


class TestbedError(Exception):
    """Anything that should stop the run with a message and exit 1."""


def _verify_ssl() -> bool:
    """CML_VERIFY_SSL, defaulting on. Matches scripts/lib/users.py's env_bool."""
    value = os.environ.get("CML_VERIFY_SSL", "").strip().lower()
    return value not in {"false", "0", "no"}


def _ssl_context() -> ssl.SSLContext:
    ctx = ssl.create_default_context()
    if not _verify_ssl():
        # The lab controller carries a self-signed certificate. CML_VERIFY_SSL=false
        # in config/mcp-env/cml.env (ADR 0004) is the operator saying skip
        # verification for this controller; scripts/lib/users.py makes the
        # same tradeoff for the same reason.
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _request(base_url: str, path: str, method: str = "GET", token: str = "",
             body: Any = None, as_json: bool = True) -> Any:
    """One HTTP call to the CML API. Raises TestbedError on any failure."""
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base_url.rstrip("/") + path, data=data, method=method)
    req.add_header("Accept", "application/json")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, context=_ssl_context(), timeout=30) as resp:
            raw = resp.read()
    except urllib.error.HTTPError as exc:
        with exc:
            detail = exc.read().decode(errors="replace")[:300]
        raise TestbedError(f"{method} {path}: HTTP {exc.code} {detail}") from None
    except urllib.error.URLError as exc:
        raise TestbedError(f"{method} {path}: {exc.reason}") from None
    if not as_json:
        return raw.decode()
    return json.loads(raw) if raw else None


def authenticate(base_url: str, username: str, password: str) -> str:
    """POST /api/v0/authenticate. Returns the bearer token. Raises TestbedError."""
    token = _request(base_url, "/api/v0/authenticate", method="POST",
                      body={"username": username, "password": password})
    if not isinstance(token, str) or not token:
        raise TestbedError(f"authentication to {base_url} failed")
    return token


def _lab_id_for_title(base_url: str, token: str, lab_title: str) -> str:
    """Resolve a lab id from its title. Raises TestbedError if none matches."""
    for lab_id in _request(base_url, "/api/v0/labs", token=token):
        lab = _request(base_url, f"/api/v0/labs/{lab_id}", token=token)
        if lab.get("lab_title") == lab_title:
            return lab_id
    raise TestbedError(f"no lab titled {lab_title!r} on {base_url}")


def fetch_testbed(base_url: str, token: str, lab_title: str) -> str:
    """Resolve lab_title to its id and return the pyATS testbed YAML text.

    Raises TestbedError if no lab on the controller carries that title, or
    if any of the underlying API calls fail (including an expired or
    otherwise rejected token, surfaced as HTTP 401).
    """
    lab_id = _lab_id_for_title(base_url, token, lab_title)
    return _request(base_url, f"/api/v0/labs/{lab_id}/pyats_testbed", token=token, as_json=False)


def _write_private(out_path: Path, text: str) -> None:
    """Write text so it is never briefly world- or group-readable.

    The testbed can carry device console credentials, so this follows
    ADR 0004: the umask narrows the window before the file exists, and the
    chmod after covers a case where out_path already existed with looser
    permissions from an earlier run.
    """
    out_path.parent.mkdir(parents=True, exist_ok=True)
    old_umask = os.umask(0o077)
    try:
        out_path.write_text(text)
    finally:
        os.umask(old_umask)
    os.chmod(out_path, 0o600)


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: gen_testbed.py <lab_title> <out_file>", file=sys.stderr)
        return 1
    lab_title, out_file = argv
    base_url = os.environ.get("CML_URL", "")
    if not base_url:
        print("gen_testbed: CML_URL is not set; source config/mcp-env/cml.env", file=sys.stderr)
        return 1
    username = os.environ.get("CML_USERNAME", "")
    password = os.environ.get("CML_PASSWORD", "")
    try:
        token = authenticate(base_url, username, password)
        testbed = fetch_testbed(base_url, token, lab_title)
    except TestbedError as exc:
        print(f"gen_testbed: {exc}", file=sys.stderr)
        return 1
    out_path = Path(out_file)
    _write_private(out_path, testbed)
    print(str(out_path))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
