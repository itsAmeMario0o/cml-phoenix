#!/usr/bin/env python3
"""Tiny MCP stdio server: answers initialize, tools/list, and tools/call for
one tool, get_cml_labs. Newline-delimited JSON-RPC, like real servers."""
from __future__ import annotations

import json
import sys


def reply(msg_id: object, result: object) -> None:
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": msg_id, "result": result}) + "\n")
    sys.stdout.flush()


def main() -> None:
    for line in sys.stdin:
        msg = json.loads(line)
        method = msg.get("method")
        if method == "initialize":
            reply(msg["id"], {"protocolVersion": "2024-11-05", "capabilities": {"tools": {}},
                              "serverInfo": {"name": "fake", "version": "0"}})
        elif method == "notifications/initialized":
            continue
        elif method == "tools/list":
            reply(msg["id"], {"tools": [{"name": "get_cml_labs", "description": "labs", "inputSchema": {"type": "object"}}]})
        elif method == "tools/call":
            if msg["params"]["name"] == "get_cml_labs":
                reply(msg["id"], {"content": [{"type": "text", "text": '[{"id": "lab-1", "title": "Spine Leaf"}]'}]})
            else:
                sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": msg["id"],
                                             "error": {"code": -32601, "message": "unknown tool"}}) + "\n")
                sys.stdout.flush()


if __name__ == "__main__":
    main()
