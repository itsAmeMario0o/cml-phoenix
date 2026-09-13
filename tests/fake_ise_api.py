#!/usr/bin/env python3
"""Minimal stand-in for ISE's ERS (External RESTful Services) API, for
tests of scripts/lib/ise_config.py. Shaped like tests/fake_cml_api.py:
serves on 127.0.0.1 at the port given as argv[1], state lives in memory.

Serves plain HTTP, not HTTPS. ise_config.py's verify-off SSL context only
changes hostname and certificate checks, both irrelevant to a plain http
connection, so the fake does not need a certificate to stand in for the
real ERS endpoint.

State starts empty: no network devices, one default policy set with no
authorization rules, unless overridden by environment variables read at
startup:

- FAKE_ISE_USER / FAKE_ISE_PASSWORD: the Basic auth credentials the fake
  checks (default admin/secret).
"""
from __future__ import annotations

import base64
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

STATE: dict = {
    "network_devices": {},  # name -> NetworkDevice dict, includes "id"
    "policy_sets": {"ps-default": {"id": "ps-default", "name": "Default"}},
    "authorization_rules": {"ps-default": {}},  # policy_set_id -> {rule name: rule dict with "id"}
    "next_id": 0,
    "user": os.environ.get("FAKE_ISE_USER", "admin"),
    "password": os.environ.get("FAKE_ISE_PASSWORD", "secret"),
}


def _next_id() -> str:
    STATE["next_id"] += 1
    return f"ise-{STATE['next_id']}"


class Handler(BaseHTTPRequestHandler):
    def _send(self, code: int, body: object = None, headers: dict[str, str] | None = None) -> None:
        data = b"" if body is None else json.dumps(body).encode()
        self.send_response(code)
        if data:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        if data:
            self.wfile.write(data)

    def _authorized(self) -> bool:
        expected = "Basic " + base64.b64encode(f"{STATE['user']}:{STATE['password']}".encode()).decode()
        return self.headers.get("Authorization", "") == expected

    def do_GET(self) -> None:  # noqa: N802
        if not self._authorized():
            self._send(401, {})
            return
        path = self.path
        if path.startswith("/ers/config/networkdevice/name/"):
            name = path.rsplit("/", 1)[-1]
            device = STATE["network_devices"].get(name)
            if device is None:
                self._send(404, {})
            else:
                self._send(200, {"NetworkDevice": device})
            return
        if path == "/ers/config/policyset":
            resources = [{"id": ps["id"], "name": ps["name"]} for ps in STATE["policy_sets"].values()]
            self._send(200, {"SearchResult": {"total": len(resources), "resources": resources}})
            return
        if path.startswith("/ers/config/policyset/") and path.endswith("/authorizationrule"):
            policy_set_id = path.split("/")[4]
            rules = STATE["authorization_rules"].get(policy_set_id, {})
            resources = [{"id": rule["id"], "name": name} for name, rule in rules.items()]
            self._send(200, {"SearchResult": {"total": len(resources), "resources": resources}})
            return
        self._send(404, {})

    def do_POST(self) -> None:  # noqa: N802
        if not self._authorized():
            self._send(401, {})
            return
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length) or b"{}")
        path = self.path
        if path == "/ers/config/networkdevice":
            device = body["NetworkDevice"]
            name = device["name"]
            if name in STATE["network_devices"]:
                self._send(400, {"description": "network device already exists"})
                return
            device_id = _next_id()
            STATE["network_devices"][name] = {**device, "id": device_id}
            location = f"https://ise.example.invalid/ers/config/networkdevice/{device_id}"
            self._send(201, None, {"Location": location})
            return
        if path.startswith("/ers/config/policyset/") and path.endswith("/authorizationrule"):
            policy_set_id = path.split("/")[4]
            if policy_set_id not in STATE["policy_sets"]:
                self._send(404, {})
                return
            rule = body["rule"]
            name = rule["name"]
            rules = STATE["authorization_rules"].setdefault(policy_set_id, {})
            if name in rules:
                self._send(400, {"description": "authorization rule already exists"})
                return
            rule_id = _next_id()
            rules[name] = {**rule, "id": rule_id}
            location = (
                "https://ise.example.invalid/ers/config/policyset/"
                f"{policy_set_id}/authorizationrule/{rule_id}"
            )
            self._send(201, None, {"Location": location})
            return
        self._send(404, {})

    def log_message(self, *_: object) -> None:
        pass


def main() -> None:
    port = int(sys.argv[1])
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
