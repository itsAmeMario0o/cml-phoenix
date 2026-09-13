#!/usr/bin/env python3
"""Apply the minimal TrustSec Phase 1 ISE policy: one network device (the
C8000v lab edge, the routed transit bridge's next hop from ADR 0003) as a
RADIUS client, and one authorization rule, enough to prove RADIUS and CoA
work end to end. There is no ISE controller in this environment (the CML
host itself is rebuilt every session, ADR 0002), so this is code that
reapplies the same two objects after every build and creates nothing on
a rerun once they exist.

    ISE_PRIVATE_IP=10.20.2.20 ISE_ADMIN_PASSWORD=... RADIUS_SECRET=... \
        python3 scripts/lib/ise_config.py

Every input comes from the environment, never argv: ISE_PRIVATE_IP, the
optional ISE_ADMIN_USERNAME (default "admin"), ISE_ADMIN_PASSWORD, and
RADIUS_SECRET. A secret on a command line shows up in a process listing
and in shell history; ADR 0004 already keeps secrets out of tracked
files and off the command line for the same reason, and this module
extends that rule to ISE's own admin password and the RADIUS shared
secret. scripts/25-ise-up.sh sources config/mcp-env/ise.env with `set -a`
before calling this, so those names are already exported.

ISE_PRIVATE_IP is a private Azure address (ADR 0003): this script runs on
the Mac, not on the CML host or ISE itself, so it cannot reach that
address directly. scripts/25-ise-up.sh's apply_ise_policy opens an SSH
local port forward through the CML host jump and sets ISE_API_BASE to
the forwarded https://127.0.0.1:<port> URL instead. When ISE_API_BASE is
set, it wins over ISE_PRIVATE_IP as the client's base URL; ISE_PRIVATE_IP
alone still works for anything that already has a direct route to it
(the fake-server unit tests, for one).

ISE's ERS (External RESTful Services) API terminates TLS with a
self-signed certificate on this disposable lab node; there is no CA to
verify against and no certificate to pin, so verification is turned off
deliberately. The routed path to it exists only inside the lab's own
address space (ADR 0003), never on a public address. Stdlib only.
"""
from __future__ import annotations

import base64
import json
import os
import ssl
import sys
import urllib.error
import urllib.request
from typing import Any

# ADR 0003: the C8000v lab edge is the routed transit bridge's next hop,
# fixed at 10.100.0.2 on the 10.100.0.0/24 transit network. It is the one
# NAD (network access device) this phase registers as a RADIUS client.
NAD_NAME = "c8000v-edge"
NAD_IP_ADDRESS = "10.100.0.2"
NAD_MASK = 32

# The out-of-the-box default policy set and a built-in ISE authorization
# profile. A full TrustSec authorization matrix is a later spec; this
# rule only has to prove that RADIUS requests from the lab edge get an
# answer and that ISE can send it a CoA afterward.
POLICY_SET_NAME = "Default"
AUTHZ_RULE_NAME = "trustsec-poc"
AUTHZ_PROFILE_NAME = "PermitAccess"


class IseConfigError(Exception):
    """Anything that should stop the run with a message and exit 1."""


class IseErsClient:
    """The ISE ERS calls this module needs. HTTP Basic auth as the ISE
    admin; stdlib urllib/ssl only, no requests dependency."""

    def __init__(self, base_url: str, username: str, password: str) -> None:
        self.base = base_url.rstrip("/") + "/ers/config"
        self.ctx = ssl.create_default_context()
        # Verification off: see the module docstring for why that is the
        # right call against this self-signed, disposable lab node.
        self.ctx.check_hostname = False
        self.ctx.verify_mode = ssl.CERT_NONE
        token = base64.b64encode(f"{username}:{password}".encode()).decode()
        self.auth_header = f"Basic {token}"

    def request(self, method: str, path: str, body: Any = None) -> tuple[Any, int, dict[str, str]]:
        """Return (parsed JSON body or None, status code, headers). A 404
        is a normal outcome for a create-if-missing check, not an error;
        every other non-2xx status raises IseConfigError."""
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.base + path, data=data, method=method)
        req.add_header("Authorization", self.auth_header)
        req.add_header("Accept", "application/json")
        if data is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, context=self.ctx, timeout=30) as resp:
                raw = resp.read()
                return (json.loads(raw) if raw else None), resp.status, dict(resp.headers)
        except urllib.error.HTTPError as exc:
            with exc:
                if exc.code == 404:
                    return None, 404, dict(exc.headers)
                detail = exc.read().decode(errors="replace")[:300]
            raise IseConfigError(f"{method} {path}: HTTP {exc.code} {detail}") from None
        except urllib.error.URLError as exc:
            raise IseConfigError(f"{method} {path}: {exc.reason}") from None


def _id_from_location(headers: dict[str, str]) -> str:
    """ISE's ERS create calls return 201 with an empty body and the new
    resource's id as the last path segment of the Location header."""
    location = headers.get("Location") or headers.get("location") or ""
    return location.rstrip("/").rsplit("/", 1)[-1]


def find_network_device_id(client: IseErsClient, name: str) -> str | None:
    body, status, _ = client.request("GET", f"/networkdevice/name/{name}")
    if status == 404 or body is None:
        return None
    return str(body["NetworkDevice"]["id"])


def create_network_device(client: IseErsClient, name: str, ip_address: str, radius_secret: str) -> str:
    payload = {
        "NetworkDevice": {
            "name": name,
            "authenticationSettings": {
                "networkProtocol": "RADIUS",
                "radiusSharedSecret": radius_secret,
                "enableKeyWrap": False,
            },
            "NetworkDeviceIPList": [{"ipaddress": ip_address, "mask": NAD_MASK}],
        }
    }
    body, status, headers = client.request("POST", "/networkdevice", payload)
    if status not in (200, 201):
        raise IseConfigError(f"POST /networkdevice for {name!r}: unexpected status {status}")
    device_id = _id_from_location(headers) or str((body or {}).get("id", ""))
    if not device_id:
        raise IseConfigError(f"POST /networkdevice for {name!r} returned no id")
    return device_id


def ensure_network_device(client: IseErsClient, name: str, ip_address: str, radius_secret: str) -> str:
    """Create-if-missing, the same idiom as scripts/lib/users.py's users
    and groups: check first, create only when absent, so a rerun after a
    rebuild neither duplicates the NAD nor changes its id."""
    existing = find_network_device_id(client, name)
    if existing:
        return existing
    return create_network_device(client, name, ip_address, radius_secret)


def find_policy_set_id(client: IseErsClient, name: str) -> str:
    body, status, _ = client.request("GET", "/policyset")
    if status == 404 or body is None:
        raise IseConfigError(f"no policy sets returned looking for {name!r}")
    resources = body.get("SearchResult", {}).get("resources", [])
    for item in resources:
        if item.get("name") == name:
            return str(item["id"])
    raise IseConfigError(f"policy set {name!r} not found")


def find_authorization_rule_id(client: IseErsClient, policy_set_id: str, name: str) -> str | None:
    body, status, _ = client.request("GET", f"/policyset/{policy_set_id}/authorizationrule")
    if status == 404 or body is None:
        return None
    resources = body.get("SearchResult", {}).get("resources", [])
    for item in resources:
        if item.get("name") == name:
            return str(item["id"])
    return None


def create_authorization_rule(
    client: IseErsClient, policy_set_id: str, name: str, nad_ip: str, profile_name: str
) -> str:
    """One rule: a RADIUS request whose NAS-IP-Address is the lab edge
    gets the named (built-in) authorization profile. That is enough to
    prove RADIUS and CoA; a real TrustSec matrix is a later spec."""
    payload = {
        "rule": {
            "name": name,
            "state": "enabled",
            "condition": {
                "conditionType": "ConditionAttributes",
                "isNegate": False,
                "dictionaryName": "Radius",
                "attributeName": "NAS-IP-Address",
                "operator": "equals",
                "attributeValue": nad_ip,
            },
            "profile": [profile_name],
        }
    }
    body, status, headers = client.request("POST", f"/policyset/{policy_set_id}/authorizationrule", payload)
    if status not in (200, 201):
        raise IseConfigError(f"POST authorizationrule for {name!r}: unexpected status {status}")
    rule_id = _id_from_location(headers) or str((body or {}).get("id", ""))
    if not rule_id:
        raise IseConfigError(f"POST authorizationrule for {name!r} returned no id")
    return rule_id


def ensure_authorization_rule(
    client: IseErsClient, policy_set_name: str, name: str, nad_ip: str, profile_name: str
) -> str:
    """Create-if-missing, same idiom as ensure_network_device."""
    policy_set_id = find_policy_set_id(client, policy_set_name)
    existing = find_authorization_rule_id(client, policy_set_id, name)
    if existing:
        return existing
    return create_authorization_rule(client, policy_set_id, name, nad_ip, profile_name)


def main(argv: list[str]) -> int:
    # No CLI arguments: every input is a secret or a private address, and
    # both stay out of argv (see module docstring, ADR 0004).
    del argv
    ise_ip = os.environ.get("ISE_PRIVATE_IP", "")
    # ADR 0003: ISE_PRIVATE_IP is not reachable from the Mac directly.
    # scripts/25-ise-up.sh sets ISE_API_BASE to a forwarded 127.0.0.1
    # URL after tunneling through the CML host jump; it wins when set.
    api_base = os.environ.get("ISE_API_BASE", "")
    admin_user = os.environ.get("ISE_ADMIN_USERNAME", "admin")
    admin_password = os.environ.get("ISE_ADMIN_PASSWORD", "")
    radius_secret = os.environ.get("RADIUS_SECRET", "")
    if not (ise_ip or api_base) or not admin_password or not radius_secret:
        print(
            "ise_config: set ISE_PRIVATE_IP or ISE_API_BASE, and ISE_ADMIN_PASSWORD "
            "and RADIUS_SECRET must be set",
            file=sys.stderr,
        )
        return 1
    base_url = api_base or f"https://{ise_ip}"
    client = IseErsClient(base_url, admin_user, admin_password)
    try:
        device_id = ensure_network_device(client, NAD_NAME, NAD_IP_ADDRESS, radius_secret)
        print(f"[OK]    network device {NAD_NAME} ({device_id})")
        rule_id = ensure_authorization_rule(client, POLICY_SET_NAME, AUTHZ_RULE_NAME, NAD_IP_ADDRESS, AUTHZ_PROFILE_NAME)
        print(f"[OK]    authorization rule {AUTHZ_RULE_NAME} ({rule_id})")
    except IseConfigError as exc:
        print(f"ise_config: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
