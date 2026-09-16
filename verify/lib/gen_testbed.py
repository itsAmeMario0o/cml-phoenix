#!/usr/bin/env python3
"""Fetch a pyATS testbed for a running CML lab, by title, over the CML API.

Task 2 of the pyATS lab-verification layer (ADR 0009). This generator is
stdlib only and deliberately separate from the pyATS venv described in
verify/README.md: the venv exists to run AEtest scripts, and fetching a
testbed from the controller needs nothing pyATS provides. Keeping it
stdlib also means it stays covered by tests/run.sh, which does not require
pyATS to be installed.

Controller credentials come only from the environment (CML_URL,
CML_USERNAME, CML_PASSWORD, CML_VERIFY_SSL, LAB_PASSWORD), the same
gitignored env files the rest of the kit reads (config/mcp-env/cml.env
and labs.env, ADR 0004). They are never taken from argv, where they
would show up in `ps` and shell history, and are never printed. CML's
own testbed export never carries real device credentials, only
placeholders (patch_terminal_server_credentials and
patch_device_credentials below); the patched testbed can carry real
ones, so the CLI writes it private from the first byte and reports only
the path it wrote.

    python3 verify/lib/gen_testbed.py <lab_title> <out_file>
"""
from __future__ import annotations

import json
import os
import re
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


def _yaml_single_quoted(value: str) -> str:
    """A YAML single-quoted scalar for value, safe for any character it
    holds (a single quote doubles to escape, per the YAML spec)."""
    return "'" + value.replace("'", "''") + "'"


def patch_terminal_server_credentials(testbed_text: str, username: str, password: str) -> str:
    """Replace the terminal_server proxy device's change_me/change_me
    placeholder with the real CML login.

    CML's /pyats_testbed export leaves every real device's credentials as
    a generic cisco/cisco guess (see patch_device_credentials below for
    the fix to that), and leaves the terminal_server proxy device, the
    CML console server every connection tunnels through, as a change_me
    placeholder instead, presumably so the export never auto-embeds the
    controller's own admin credentials. Without this, every device
    connection fails through the proxy with "Permission denied" (caught
    live, Task 7).

    Plain text substitution, not a YAML parse and rewrite, since this
    script stays stdlib only by design (see the module docstring).
    Raises TestbedError if the expected placeholder is not found, rather
    than silently leaving change_me in place were CML's export format to
    change.
    """
    placeholder = "      default:\n        password: change_me\n        username: change_me\n"
    if placeholder not in testbed_text:
        raise TestbedError(
            "terminal_server's change_me placeholder not found; "
            "CML's testbed export format may have changed"
        )
    replacement = (
        "      default:\n"
        f"        password: {_yaml_single_quoted(password)}\n"
        f"        username: {_yaml_single_quoted(username)}\n"
    )
    return testbed_text.replace(placeholder, replacement, 1)


_DEVICE_BLOCK_SPLIT_RE = re.compile(r"(?=^  \S[\w-]*:\n)", re.M)
_DEVICE_NAME_RE = re.compile(r"^  (\S[\w-]*):\n")
_DEVICE_CREDENTIALS_PLACEHOLDER = (
    "      default:\n        password: cisco\n        username: cisco\n"
)
# Real per-device username, labs/README.md's node table. Every NX-OS
# switch (checked by os: nxos, not by name, so a scenario adding more
# switches needs no change here) uses admin; the Linux hosts default to
# cisco except kind-host, which needs kindops instead (confirmed live,
# Task 7: kind-host rejects cisco outright, "Login incorrect", while
# red-endpoint and blue-endpoint accept it with the exact same patch).
_HOST_USERNAME_OVERRIDES = {"kind-host": "kindops"}


def patch_device_credentials(testbed_text: str, lab_password: str) -> str:
    """Replace every real lab node's cisco/cisco placeholder credentials
    with its actual configured login.

    CML's /pyats_testbed export defaults every real device to the same
    cisco/cisco guess regardless of platform or per-node day-0 identity.
    That is wrong three ways: the NX-OS switches' real username is admin
    (day-0 sets "username admin password <LAB_PASSWORD>"), kind-host's is
    kindops, not cisco (labs/README.md's node table), and everywhere the
    real password is LAB_PASSWORD, never the literal word "cisco" (all
    caught live, Task 7, once the terminal_server proxy fix above got far
    enough to actually reach device-level login). terminal_server itself
    is untouched here; its change_me placeholder is
    patch_terminal_server_credentials's job, not this one, and its
    literal "cisco" text never matches this function's placeholder.

    Per-device-block text substitution, not a YAML parse and rewrite,
    for the same stdlib-only reason as patch_terminal_server_credentials.
    Splits on each top-level "  <name>:" device header (CML's export
    indents every device two spaces under "devices:") rather than
    scanning line by line, since a device's os: line comes after its
    credentials: block in CML's output, not before it. Raises
    TestbedError if no device carries the expected placeholder at all,
    rather than silently leaving cisco/cisco in place were CML's export
    format to change.
    """
    chunks = _DEVICE_BLOCK_SPLIT_RE.split(testbed_text)
    patched_any = False
    for i, chunk in enumerate(chunks):
        name_match = _DEVICE_NAME_RE.match(chunk)
        if not name_match or name_match.group(1) == "terminal_server":
            continue
        if _DEVICE_CREDENTIALS_PLACEHOLDER not in chunk:
            continue
        if "\n    os: nxos\n" in chunk:
            username = "admin"
        else:
            username = _HOST_USERNAME_OVERRIDES.get(name_match.group(1), "cisco")
        replacement = (
            "      default:\n"
            f"        password: {_yaml_single_quoted(lab_password)}\n"
            f"        username: {_yaml_single_quoted(username)}\n"
        )
        chunks[i] = chunk.replace(_DEVICE_CREDENTIALS_PLACEHOLDER, replacement, 1)
        patched_any = True
    if not patched_any:
        raise TestbedError(
            "no device cisco/cisco placeholder credentials found; "
            "CML's testbed export format may have changed"
        )
    return "".join(chunks)


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
    lab_password = os.environ.get("LAB_PASSWORD", "")
    if not lab_password:
        print("gen_testbed: LAB_PASSWORD is not set; source config/mcp-env/labs.env", file=sys.stderr)
        return 1
    try:
        token = authenticate(base_url, username, password)
        testbed = fetch_testbed(base_url, token, lab_title)
        testbed = patch_terminal_server_credentials(testbed, username, password)
        testbed = patch_device_credentials(testbed, lab_password)
    except TestbedError as exc:
        print(f"gen_testbed: {exc}", file=sys.stderr)
        return 1
    out_path = Path(out_file)
    _write_private(out_path, testbed)
    print(str(out_path))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
