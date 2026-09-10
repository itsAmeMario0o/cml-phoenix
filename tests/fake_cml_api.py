#!/usr/bin/env python3
"""Minimal stand-in for the CML controller API, for tests of cml-remote.sh.

Serves on 127.0.0.1 at the port given as argv[1]. State lives in memory:
three labs (one started, two stopped) and a registered license, unless
overridden by environment variables read at startup:

- FAKE_LABS=0 starts with no labs (default: labs present).
- FAKE_DEREGISTER_FAILS=1 makes DELETE /licensing/deregistration respond
  202 but leave the registration state unchanged (default: it succeeds).
"""
from __future__ import annotations

import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse


def _default_labs() -> dict:
    return {
        "lab-1": {"lab_title": "Spine Leaf", "state": "STARTED"},
        "lab-2": {"lab_title": "TrustSec Demo", "state": "STOPPED"},
        "lab-3": {"lab_title": "VLAN/Trunk Demo", "state": "STOPPED"},
    }


STATE: dict = {
    "labs": _default_labs() if os.environ.get("FAKE_LABS") != "0" else {},
    "registration": os.environ.get("FAKE_REGISTRATION", "REGISTERED"),
    "deregister_fails": os.environ.get("FAKE_DEREGISTER_FAILS") == "1",
    # Users and groups, shaped like GET /users and GET /groups on 2.10.
    # Passwords are kept aside so a created user can authenticate.
    "users": {"u-admin": {"id": "u-admin", "username": "admin", "fullname": "", "email": "",
                          "admin": True, "groups": []}},
    "passwords": {"admin": "secret"},
    "groups": {},
}


def _user_by_name(username: str) -> dict | None:
    return next((u for u in STATE["users"].values() if u["username"] == username), None)


class Handler(BaseHTTPRequestHandler):
    def _send(self, code: int, body: object, content_type: str = "application/json") -> None:
        data = body.encode() if isinstance(body, str) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _authorized(self) -> bool:
        return self.headers.get("Authorization", "").startswith("Bearer FAKE-TOKEN")

    def do_POST(self) -> None:  # noqa: N802
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        if self.path == "/api/v0/authenticate":
            creds = json.loads(body)
            name = creds.get("username", "")
            if STATE["passwords"].get(name) == creds.get("password"):
                self._send(200, json.dumps("FAKE-TOKEN" if name == "admin" else f"FAKE-TOKEN-{name}"))
            else:
                self._send(403, {"description": "bad credentials"})
            return
        if not self._authorized():
            self._send(401, {})
            return
        if self.path == "/api/v0/users":
            data = json.loads(body)
            if _user_by_name(data["username"]) is not None:
                self._send(422, {"description": "User already exists."})
                return
            uid = f"u-{len(STATE['users'])}"
            STATE["users"][uid] = {"id": uid, "username": data["username"], "fullname": data.get("fullname", ""),
                                   "email": data.get("email", ""), "admin": bool(data.get("admin")),
                                   "groups": list(data.get("groups", []))}
            STATE["passwords"][data["username"]] = data["password"]
            for gid in data.get("groups", []):
                STATE["groups"][gid]["members"].append(uid)
            self._send(200, STATE["users"][uid])
            return
        if self.path == "/api/v0/groups":
            data = json.loads(body)
            gid = f"g-{len(STATE['groups']) + 1}"
            STATE["groups"][gid] = {"id": gid, "name": data["name"], "description": data.get("description", ""),
                                    "members": list(data.get("members", []))}
            self._send(200, STATE["groups"][gid])
            return
        if self.path.startswith("/api/v0/import"):
            # Real CML reads the body as YAML. Here the title comes from the
            # query and the body is kept verbatim for the download endpoint.
            title = parse_qs(urlparse(self.path).query).get("title", ["Imported"])[0]
            STATE["labs"]["lab-new"] = {"lab_title": title, "state": "STOPPED", "topology": body.decode()}
            self._send(200, {"id": "lab-new", "warnings": []})
            return
        self._send(404, {})

    def do_GET(self) -> None:  # noqa: N802
        if not self._authorized():
            self._send(401, {})
            return
        if self.path == "/api/v0/labs":
            self._send(200, list(STATE["labs"]))
        elif self.path == "/api/v0/users":
            self._send(200, list(STATE["users"].values()))
        elif self.path == "/api/v0/groups":
            self._send(200, list(STATE["groups"].values()))
        elif self.path == "/api/v0/licensing":
            self._send(200, {"registration": {"status": STATE["registration"]}})
        elif self.path.startswith("/api/v0/labs/") and self.path.endswith("/download"):
            lab_id = self.path.split("/")[4]
            lab = STATE["labs"][lab_id]
            self._send(200, lab.get("topology", f"lab:\n  title: {lab['lab_title']}\n"), "text/plain")
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
            if not STATE["deregister_fails"]:
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
