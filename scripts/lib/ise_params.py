#!/usr/bin/env python3
# TENTATIVE-OBSOLETE (2026-09-13). This module only serves the retired
# `az deployment group create` path (ADR 0008 amendment); the portal deploy
# in docs/ISE-MARKETPLACE-DEPLOY.md does not use it. Kept, not deleted,
# because roadmap item 19 (ISEEE ephemeral ISE) may revive an automated
# deploy that renders parameters again.
"""Render the Azure deployment parameters file for config/ise/template.json
(ADR 0008: ISE deploys by `az deployment group create` against Cisco's
Azure solution template, not by hand-rolled userData). scripts/25-ise-up.sh
(Task 3) passes the file this module writes to
`az deployment group create --parameters @<file>`.

render_parameters(env, pubkey, nsg_name) builds the parameters object in
memory; the CLI writes it to disk. The ISE admin password is the one
secret this module handles (ADR 0004: no secret in a tracked file, none
on a command line). It comes from ISE_ADMIN_PASSWORD in os.environ, never
from argv, where it would show up in a process listing and in shell
history. The rendered file carries that same secret as plain JSON, so
main() creates it under a restrictive umask and chmods it to 0600 before
anything else on the host gets a chance to read it.

    ISE_ADMIN_PASSWORD=... python3 scripts/lib/ise_params.py out.json --nsg ise-nsg

Stdlib only.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any

# ADR 0008: ISE joins the network the persistent Terraform root already
# built. This module never creates or names a vnet or subnet of its own.
MANAGEMENT_NETWORK = "vnet-cml-lab"
MANAGEMENT_SUBNET = "snet-apps"
PUBLIC_IP_RESOURCE_GROUP = "rg-cml-lab"

DEFAULT_PUBKEY_FILE = "keys/cml-lab.pub"


def _value(v: Any) -> dict[str, Any]:
    """Wrap a plain value in the {"value": ...} shape an ARM deployment
    parameters file requires for every parameter."""
    return {"value": v}


def render_parameters(env: dict[str, str], pubkey: str, nsg_name: str) -> dict[str, Any]:
    """Build the Azure deployment parameters object for
    config/ise/template.json. The parameter names below match that
    template's `parameters` block exactly (ADR 0008 leaves every
    parameter as Cisco shipped it, including its casing); keep the two
    files in sync if the template is ever re-copied from a newer
    Marketplace version.

    Raises KeyError if ISE_ADMIN_PASSWORD is missing from *env*. That
    failure must happen here, loudly, rather than let the deploy fall
    through to whatever default systemPassword Cisco's template ships
    (ADR 0004: no secret, including a stand-in default, reaches a real
    deploy without an operator deliberately setting it).
    """
    return {
        "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
        "contentVersion": "1.0.0.0",
        "parameters": {
            "hostName": _value(env["ISE_HOSTNAME"]),
            "SSHKeyPairName": _value(pubkey),
            "managementNetwork": _value(MANAGEMENT_NETWORK),
            "managementSubnet": _value(MANAGEMENT_SUBNET),
            "managementNSG": _value(nsg_name),
            "managementPrivateIP": _value(env["ISE_PRIVATE_IP"]),
            "publicIpName": _value(env["ISE_PUBLIC_IP_NAME"]),
            "publicIpNewOrExisting": _value("new"),
            "publicIpResourceGroupName": _value(PUBLIC_IP_RESOURCE_GROUP),
            "publicIpAllocationMethod": _value("Static"),
            "publicIpSku": _value("Standard"),
            "timeZone": _value(env["ISE_TIMEZONE"]),
            "instanceType": _value(env["ISE_VM_SIZE"]),
            "storageType": _value(env["ISE_STORAGE_TYPE"]),
            "volumeSize": _value(int(env["ISE_VOLUME_SIZE"])),
            "DNSDomain": _value(env["ISE_DNS_DOMAIN"]),
            "primaryNameServer": _value(env["ISE_PRIMARY_NAMESERVER"]),
            "primaryNTPServer": _value(env["ISE_PRIMARY_NTP"]),
            "ERS": _value(env["ISE_ERS"]),
            "PXGrid": _value(env["ISE_PXGRID"]),
            # Last, so KeyError on the missing secret is the one thing
            # this function can fail on once every other required key is
            # present (the failing test only removes this one).
            "systemPassword": _value(env["ISE_ADMIN_PASSWORD"]),
        },
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Render the ISE deployment parameters file.")
    parser.add_argument("out_file", help="path to write the parameters JSON")
    parser.add_argument("--nsg", required=True, help="name of the ISE management NSG")
    args = parser.parse_args(argv)

    pubkey_file = Path(os.environ.get("ISE_PUBKEY_FILE", DEFAULT_PUBKEY_FILE))
    try:
        pubkey = pubkey_file.read_text().strip()
    except OSError as exc:
        print(f"ise_params: cannot read public key {pubkey_file}: {exc}", file=sys.stderr)
        return 1

    try:
        doc = render_parameters(os.environ, pubkey, args.nsg)
    except KeyError as exc:
        print(f"ise_params: missing required environment variable {exc}", file=sys.stderr)
        return 1

    out_path = Path(args.out_file)
    # Restrict the file's mode before it exists, not after: a gap between
    # create and chmod would let another process on the same host read
    # the ISE admin password while it is still world- or group-readable
    # (ADR 0004, senior-secops).
    previous_umask = os.umask(0o077)
    try:
        out_path.write_text(json.dumps(doc, indent=2) + "\n")
    finally:
        os.umask(previous_umask)
    os.chmod(out_path, 0o600)

    # Confirmation only: the path and mode, never a parameter value.
    print(f"[OK]    wrote {out_path} (0600)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
