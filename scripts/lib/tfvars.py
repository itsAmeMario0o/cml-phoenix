#!/usr/bin/env python3
"""Parse the HCL subset used by config/cml.tfvars.

Supported, one assignment per line:
    key = "string"
    key = 123        (also negative)
    key = true | false
    key = ["a", "b"] (strings only, may be empty)
    # comments, whole line or after a value

Anything else raises ValueError naming the line. Stdlib only.
"""
from __future__ import annotations

import re
from pathlib import Path
from typing import Any

_ASSIGN = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$")
_STRING = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*(?:#.*)?$')
_NUMBER = re.compile(r"^(-?\d+)\s*(?:#.*)?$")
_BOOL = re.compile(r"^(true|false)\s*(?:#.*)?$")
_LIST = re.compile(r"^\[(.*)\]\s*(?:#.*)?$")
_LIST_ITEM = re.compile(r'"((?:[^"\\]|\\.)*)"')


def _parse_value(raw: str, lineno: int) -> Any:
    if m := _STRING.match(raw):
        return m.group(1)
    if m := _NUMBER.match(raw):
        return int(m.group(1))
    if m := _BOOL.match(raw):
        return m.group(1) == "true"
    if m := _LIST.match(raw):
        body = m.group(1).strip()
        if not body:
            return []
        items = _LIST_ITEM.findall(body)
        leftover = _LIST_ITEM.sub("", body).replace(",", "").strip()
        if leftover:
            raise ValueError(f"line {lineno}: lists may hold only quoted strings")
        return items
    raise ValueError(f"line {lineno}: unsupported value syntax: {raw!r}")


def parse_tfvars(text: str) -> dict[str, Any]:
    """Return a dict of the assignments in *text*."""
    result: dict[str, Any] = {}
    for lineno, line in enumerate(text.splitlines(), start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        m = _ASSIGN.match(line)
        if not m:
            raise ValueError(f"line {lineno}: expected 'key = value'")
        result[m.group(1)] = _parse_value(m.group(2), lineno)
    return result


def load(path: Path) -> dict[str, Any]:
    """Parse the file at *path*."""
    return parse_tfvars(path.read_text())
