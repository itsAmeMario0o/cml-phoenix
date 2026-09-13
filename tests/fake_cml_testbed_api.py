#!/usr/bin/env python3
"""Minimal stand-in for the CML authenticate/labs/pyats_testbed endpoints,
for tests of verify/lib/gen_testbed.py. Modeled on tests/fake_cml_api.py.

Serves on 127.0.0.1 at the port given as argv[1]. State lives in memory:
one lab with a fixed title and a small testbed YAML body. The only
accepted credentials are FAKE_USERNAME/FAKE_PASSWORD (default admin/secret),
and the only accepted bearer token is FAKE-TOKEN; anything else on a
protected endpoint gets 401.
"""
from __future__ import annotations

import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

LAB_ID = "lab-1"
LAB_TITLE = "TrustSec Demo"
TESTBED_YAML = (
    "testbed:\n"
    "  name: trustsec-demo\n"
    "devices:\n"
    "  switch1:\n"
    "    os: iosxe\n"
    "    connections:\n"
    "      console:\n"
    "        protocol: telnet\n"
    "        ip: 127.0.0.1\n"
    "        port: 17001\n"
)

USERNAME = os.environ.get("FAKE_USERNAME", "admin")
PASSWORD = os.environ.get("FAKE_PASSWORD", "secret")
TOKEN = "FAKE-TOKEN"

STATE: dict = {
    "labs": {LAB_ID: {"lab_title": LAB_TITLE, "testbed": TESTBED_YAML}},
}


class Handler(BaseHTTPRequestHandler):
    def _send(self, code: int, body: object, content_type: str = "application/json") -> None:
        data = body.encode() if isinstance(body, str) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _authorized(self) -> bool:
        return self.headers.get("Authorization", "") == f"Bearer {TOKEN}"

    def do_POST(self) -> None:  # noqa: N802
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        if self.path == "/api/v0/authenticate":
            creds = json.loads(body) if body else {}
            if creds.get("username") == USERNAME and creds.get("password") == PASSWORD:
                self._send(200, json.dumps(TOKEN))
            else:
                self._send(403, {"description": "bad credentials"})
            return
        self._send(404, {})

    def do_GET(self) -> None:  # noqa: N802
        if not self._authorized():
            self._send(401, {})
            return
        if self.path == "/api/v0/labs":
            self._send(200, list(STATE["labs"]))
        elif self.path.startswith("/api/v0/labs/") and self.path.endswith("/pyats_testbed"):
            lab_id = self.path.split("/")[4]
            lab = STATE["labs"].get(lab_id)
            if lab is None:
                self._send(404, {})
                return
            self._send(200, lab["testbed"], "text/plain")
        elif self.path.startswith("/api/v0/labs/"):
            lab_id = self.path.split("/")[4]
            lab = STATE["labs"].get(lab_id)
            if lab is None:
                self._send(404, {})
                return
            self._send(200, {"id": lab_id, "lab_title": lab["lab_title"]})
        else:
            self._send(404, {})

    def log_message(self, *_: object) -> None:
        pass


def main() -> None:
    port = int(sys.argv[1])
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
