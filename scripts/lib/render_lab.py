#!/usr/bin/env python3
"""Fill the placeholders in a tracked lab topology so it can be imported.

    LAB_PASSWORD=... python3 scripts/lib/render_lab.py labs/x.yaml \
        --pubkey keys/cml-lab.pub --out exports/.rendered/x.yaml

Tracked topologies under labs/ carry __NAME__ placeholders instead of
real values (ADR 0006). Every __NAME__ is filled from the environment
variable NAME, except __LAB_SSH_PUBKEY__, which comes from the key file.
Values pass through the environment, never argv, so they stay out of
process listings. Exit 1 with a message on stderr naming every
placeholder whose variable is unset or empty, or when the key file is
unreadable. The output file is created with mode 0600. Stdlib only.
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

PLACEHOLDER = re.compile(r"__([A-Z][A-Z0-9_]*)__")
PUBKEY = "LAB_SSH_PUBKEY"


def render(text: str, values: dict[str, str], pubkey: str) -> str:
    """Substitute every placeholder. Raises ValueError naming what is missing."""
    names = set(PLACEHOLDER.findall(text))
    filled = {k: v for k, v in values.items() if v}
    if pubkey:
        filled[PUBKEY] = pubkey
    missing = sorted(n for n in names if n not in filled)
    if missing:
        raise ValueError("missing or empty: " + ", ".join(missing))
    return PLACEHOLDER.sub(lambda m: filled[m.group(1)], text)


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
        rendered = render(text, dict(os.environ), pubkey)
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
