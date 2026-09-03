#!/usr/bin/env python3
"""Tiny MCP stdio server: answers initialize, tools/list, and tools/call for
two tools, get_cml_labs and boom (which always errors). Newline-delimited
JSON-RPC, like real servers."""
from __future__ import annotations

import json
import sys


def reply(msg_id: object, result: object) -> None:
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": msg_id, "result": result}) + "\n")
    sys.stdout.flush()


def reply_error(msg_id: object, code: int, message: str) -> None:
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": msg_id,
                                 "error": {"code": code, "message": message}}) + "\n")
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
            reply(msg["id"], {"tools": [
                {"name": "get_cml_labs", "description": "labs", "inputSchema": {"type": "object"}},
                {"name": "boom", "description": "always errors", "inputSchema": {"type": "object"}},
            ]})
        elif method == "tools/call":
            name = msg["params"]["name"]
            if name == "get_cml_labs":
                reply(msg["id"], {"content": [{"type": "text", "text": '[{"id": "lab-1", "title": "Spine Leaf"}]'}]})
            elif name == "boom":
                reply_error(msg["id"], -32000, "boom failed")
            else:
                reply_error(msg["id"], -32601, "unknown tool")


if __name__ == "__main__":
    main()
