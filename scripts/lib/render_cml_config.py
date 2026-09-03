#!/usr/bin/env python3
"""Render config/cml.yml from the template, cml.tfvars, refplat.txt, and
values passed as --set NAME=VALUE (the persistent Terraform outputs).

Exit 0 on success. Exit 1 with a message on stderr naming every missing
placeholder, an open CIDR, or a malformed input. Never touches Terraform so
the fork stays unaware of this repo. ADR 0004 for why secrets pass this way.
"""
from __future__ import annotations

import argparse
import os
import string
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
import tfvars  # noqa: E402

REQUIRED_TFVARS = [
    "smartlicense_token", "license_flavor", "allowed_ipv4_subnets_mgmt",
    "allowed_ipv4_subnets_cml2", "vm_size", "os_disk_size_gb", "spot_enabled",
    "spot_max_bid_price", "sas_validity", "software_package",
]


def yaml_flow_list(items: list[str]) -> str:
    return "[" + ", ".join(f'"{item}"' for item in items) + "]"


def yaml_block_list(items: list[str], indent: int = 4) -> str:
    return "\n".join(f"{' ' * indent}- {item}" for item in items)


def read_refplat(path: Path) -> tuple[list[str], list[str]]:
    definitions: list[str] = []
    images: list[str] = []
    for lineno, line in enumerate(path.read_text().splitlines(), start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        parts = stripped.split()
        if len(parts) != 2:
            raise ValueError(f"{path}: line {lineno}: expected 'definition image'")
        if parts[0] not in definitions:
            definitions.append(parts[0])
        images.append(parts[1])
    if not images:
        raise ValueError(f"{path}: no images listed")
    return definitions, images


def check_cidrs(values: dict[str, Any]) -> None:
    for key in ("allowed_ipv4_subnets_mgmt", "allowed_ipv4_subnets_cml2"):
        cidrs = values[key]
        if not isinstance(cidrs, list) or not cidrs:
            raise ValueError(f"{key} must be a non-empty list")
        if "0.0.0.0/0" in cidrs:
            raise ValueError(f"{key} contains 0.0.0.0/0, which is never allowed")


def build_mapping(values: dict[str, Any], refplat: tuple[list[str], list[str]], sets: dict[str, str]) -> dict[str, str]:
    definitions, images = refplat
    mapping = dict(sets)
    mapping.update({
        "LICENSE_TOKEN": str(values["smartlicense_token"]),
        "LICENSE_FLAVOR": str(values["license_flavor"]),
        "ALLOWED_MGMT": yaml_flow_list(values["allowed_ipv4_subnets_mgmt"]),
        "ALLOWED_CML2": yaml_flow_list(values["allowed_ipv4_subnets_cml2"]),
        "VM_SIZE": str(values["vm_size"]),
        "OS_DISK_SIZE_GB": str(values["os_disk_size_gb"]),
        "SPOT_ENABLED": "true" if values["spot_enabled"] else "false",
        "SPOT_MAX_BID_PRICE": str(values["spot_max_bid_price"]),
        "SAS_VALIDITY": str(values["sas_validity"]),
        "SOFTWARE_PACKAGE": str(values["software_package"]),
        "REFPLAT_DEFINITIONS": yaml_block_list(definitions),
        "REFPLAT_IMAGES": yaml_block_list(images),
    })
    return mapping


def render(template_text: str, mapping: dict[str, str]) -> str:
    template = string.Template(template_text)
    needed = {m.group("named") or m.group("braced") for m in template.pattern.finditer(template_text)}
    needed.discard(None)
    missing = sorted(name for name in needed if name not in mapping)
    if missing:
        raise KeyError("missing placeholders: " + ", ".join(missing))
    return template.substitute(mapping)


def parse_sets(pairs: list[str]) -> dict[str, str]:
    sets: dict[str, str] = {}
    for pair in pairs:
        if "=" not in pair:
            raise ValueError(f"--set expects NAME=VALUE, got {pair!r}")
        name, value = pair.split("=", 1)
        sets[name.strip()] = value
    return sets


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--template", required=True, type=Path)
    parser.add_argument("--tfvars", required=True, type=Path)
    parser.add_argument("--refplat", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--set", action="append", default=[], metavar="NAME=VALUE")
    args = parser.parse_args(argv)
    try:
        values = tfvars.load(args.tfvars)
        missing = [k for k in REQUIRED_TFVARS if k not in values]
        if missing:
            raise ValueError(f"{args.tfvars}: missing keys: {', '.join(missing)}")
        check_cidrs(values)
        mapping = build_mapping(values, read_refplat(args.refplat), parse_sets(args.set))
        rendered = render(args.template.read_text(), mapping)
    except (ValueError, KeyError, OSError) as exc:
        print(f"render_cml_config: {exc}", file=sys.stderr)
        return 1
    args.out.write_text(rendered)
    os.chmod(args.out, 0o600)
    print(f"rendered {args.out} ({len(mapping)} values)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
