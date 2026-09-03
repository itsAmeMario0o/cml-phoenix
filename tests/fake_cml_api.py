#!/usr/bin/env python3
"""Minimal stand-in for the CML controller API, for tests of cml-remote.sh.

Serves on 127.0.0.1 at the port given as argv[1]. State lives in memory:
two labs, one started, one stopped, and a registered license.
"""
from __future__ import annotations

import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

STATE: dict = {
    "labs": {
        "lab-1": {"lab_title": "Spine Leaf", "state": "STARTED"},
        "lab-2": {"lab_title": "TrustSec Demo", "state": "STOPPED"},
    },
    "registration": "REGISTERED",
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
        return self.headers.get("Authorization") == "Bearer FAKE-TOKEN"

    def do_POST(self) -> None:  # noqa: N802
        if self.path == "/api/v0/authenticate":
            length = int(self.headers.get("Content-Length", "0"))
            creds = json.loads(self.rfile.read(length))
            if creds == {"username": "admin", "password": "secret"}:
                self._send(200, json.dumps("FAKE-TOKEN"))
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
        elif self.path == "/api/v0/licensing":
            self._send(200, {"registration": {"status": STATE["registration"]}})
        elif self.path.startswith("/api/v0/labs/") and self.path.endswith("/download"):
            lab_id = self.path.split("/")[4]
            self._send(200, f"lab:\n  title: {STATE['labs'][lab_id]['lab_title']}\n", "text/plain")
        elif self.path.startswith("/api/v0/labs/"):
            lab_id = self.path.split("/")[4]
            self._send(200, {"id": lab_id, **STATE["labs"][lab_id]})
        else:
            self._send(404, {})

    def do_PUT(self) -> None:  # noqa: N802
        if not self._authorized():
            self._send(401, {})
            return
        if self.path.startswith("/api/v0/labs/") and self.path.endswith("/stop"):
            STATE["labs"][self.path.split("/")[4]]["state"] = "STOPPED"
            self._send(204, "")
        else:
            self._send(404, {})

    def do_DELETE(self) -> None:  # noqa: N802
        if not self._authorized():
            self._send(401, {})
            return
        if self.path == "/api/v0/licensing/deregistration":
            STATE["registration"] = "NOT_REGISTERED"
            self._send(202, {})
        else:
            self._send(404, {})

    def log_message(self, *_: object) -> None:
        pass


def main() -> None:
    port = int(sys.argv[1])
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
