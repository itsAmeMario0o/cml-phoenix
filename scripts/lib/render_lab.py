#!/usr/bin/env python3
"""Fill the placeholders in a tracked lab topology so it can be imported.

    LAB_PASSWORD=... python3 scripts/lib/render_lab.py labs/x.yaml \
        --pubkey keys/cml-lab.pub --out exports/.rendered/x.yaml

Tracked topologies under labs/ carry __LAB_PASSWORD__ and __LAB_SSH_PUBKEY__
instead of real values (ADR 0006). The password comes from the environment,
never from argv, so it stays out of process listings. Exit 1 with a message
on stderr when the password is empty, the key file is unreadable, or any
__NAME__ placeholder is still present after substitution. The output file
is created with mode 0600. Stdlib only.
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

PLACEHOLDER = re.compile(r"__[A-Z][A-Z0-9_]*__")
PASSWORD = "__LAB_PASSWORD__"
PUBKEY = "__LAB_SSH_PUBKEY__"


def render(text: str, password: str, pubkey: str) -> str:
    """Substitute both placeholders. Raises ValueError for anything left over."""
    if not password:
        raise ValueError("LAB_PASSWORD is empty")
    if not pubkey:
        raise ValueError("public key is empty")
    out = text.replace(PASSWORD, password).replace(PUBKEY, pubkey)
    leftover = sorted(set(PLACEHOLDER.findall(out)))
    if leftover:
        raise ValueError("unfilled placeholders: " + ", ".join(leftover))
    return out


def lab_title(text: str) -> str:
    """The lab title from the topology header, or an empty string."""
    match = re.search(r"^lab:\n(?:  .*\n)*?  title:[ \t]*(.+?)[ \t]*$", text, re.MULTILINE)
    return match.group(1).strip("'\"") if match else ""


def write_private(path: Path, content: str) -> None:
    """Write with mode 0600 from the first byte, replacing any old file.

    O_CREAT only applies the mode to a new inode, so an old copy with a
    wider mode is removed first rather than reused.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        path.unlink()
    except FileNotFoundError:
        pass
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as handle:
        handle.write(content)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("topology", type=Path)
    parser.add_argument("--pubkey", type=Path, required=True, help="public key file, one line")
    parser.add_argument("--out", type=Path, help="output file (default stdout)")
    parser.add_argument("--print-title", action="store_true", help="print the lab title and exit")
    args = parser.parse_args(argv)

    try:
        text = args.topology.read_text()
    except OSError as exc:
        print(f"render_lab: cannot read {args.topology}: {exc}", file=sys.stderr)
        return 1
    if args.print_title:
        print(lab_title(text))
        return 0
    try:
        pubkey = args.pubkey.read_text().strip()
    except OSError as exc:
        print(f"render_lab: cannot read {args.pubkey}: {exc}", file=sys.stderr)
        return 1
    try:
        rendered = render(text, os.environ.get("LAB_PASSWORD", ""), pubkey)
    except ValueError as exc:
        print(f"render_lab: {exc}", file=sys.stderr)
        return 1
    if args.out:
        write_private(args.out, rendered)
    else:
        sys.stdout.write(rendered)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
