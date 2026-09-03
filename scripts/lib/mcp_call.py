#!/usr/bin/env python3
"""Call one tool on an MCP stdio server and print its text result.

    python3 scripts/lib/mcp_call.py --cmd "bash scripts/mcp-cml.sh" --tool get_cml_labs

Does the initialize handshake, checks the tool is listed, calls it, prints
the concatenated text content. Exit 0 ok, 1 on error or unknown tool, 2 on
timeout. Stdlib only. Used by scripts/90-smoke-test.sh to prove cml-mcp can
reach the controller from the Mac.
"""
from __future__ import annotations

import argparse
import json
import shlex
import subprocess
import sys
import threading
from typing import Any

PROTOCOL = "2024-11-05"


class McpClient:
    def __init__(self, cmd: str, timeout: float) -> None:
        self.proc = subprocess.Popen(shlex.split(cmd), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, text=True, bufsize=1)
        self.timeout = timeout
        self.next_id = 1
        self._reader: threading.Thread | None = None

    def _write(self, msg: dict[str, Any]) -> None:
        assert self.proc.stdin is not None
        self.proc.stdin.write(json.dumps(msg) + "\n")
        self.proc.stdin.flush()

    def _read_response(self, msg_id: int) -> dict[str, Any]:
        assert self.proc.stdout is not None
        if self._reader is not None and self._reader.is_alive():
            raise RuntimeError("previous request still pending")
        result: dict[str, Any] = {}

        def reader() -> None:
            for line in self.proc.stdout:
                line = line.strip()
                if not line:
                    continue
                try:
                    msg = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(msg, dict):
                    continue
                if msg.get("id") == msg_id:
                    result.update(msg)
                    return

        t = threading.Thread(target=reader, daemon=True)
        self._reader = t
        t.start()
        t.join(self.timeout)
        if t.is_alive():
            raise TimeoutError(f"no response to request {msg_id} in {self.timeout}s")
        if not result:
            raise RuntimeError("server closed the stream: " + self._stderr_tail())
        return result

    def _stderr_tail(self) -> str:
        assert self.proc.stderr is not None
        if self.proc.poll() is None:
            return "server still running, stdout closed"
        try:
            return self.proc.stderr.read()[-2000:]
        except ValueError:
            return ""

    def request(self, method: str, params: dict[str, Any] | None = None) -> Any:
        msg_id = self.next_id
        self.next_id += 1
        self._write({"jsonrpc": "2.0", "id": msg_id, "method": method, "params": params or {}})
        response = self._read_response(msg_id)
        if "error" in response:
            raise RuntimeError(f"{method}: {response['error'].get('message', response['error'])}")
        return response["result"]

    def notify(self, method: str) -> None:
        self._write({"jsonrpc": "2.0", "method": method})

    def close(self) -> None:
        try:
            if self.proc.stdin:
                self.proc.stdin.close()
            self.proc.terminate()
            self.proc.wait(timeout=5)
        except (OSError, subprocess.TimeoutExpired):
            self.proc.kill()
            try:
                self.proc.wait(timeout=5)
            except (OSError, subprocess.TimeoutExpired):
                pass


def parse_args_kv(pairs: list[str]) -> dict[str, Any]:
    out: dict[str, Any] = {}
    for pair in pairs:
        key, _, value = pair.partition("=")
        out[key] = value
    return out


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cmd", required=True, help="server command line")
    parser.add_argument("--tool", required=True)
    parser.add_argument("--arg", action="append", default=[], metavar="KEY=VALUE")
    parser.add_argument("--timeout", type=float, default=60.0)
    args = parser.parse_args(argv)

    try:
        client = McpClient(args.cmd, args.timeout)
    except OSError as exc:
        print(f"mcp_call: cannot start server: {exc}", file=sys.stderr)
        return 1
    try:
        client.request("initialize", {"protocolVersion": PROTOCOL, "capabilities": {},
                                      "clientInfo": {"name": "cml-azure-lab-smoke", "version": "1"}})
        client.notify("notifications/initialized")
        tools = {t["name"] for t in client.request("tools/list").get("tools", [])}
        if args.tool not in tools:
            print(f"mcp_call: tool {args.tool!r} not offered. Offered: {sorted(tools)}", file=sys.stderr)
            return 1
        result = client.request("tools/call", {"name": args.tool, "arguments": parse_args_kv(args.arg)})
        if result.get("isError"):
            print(f"mcp_call: tool reported an error: {result}", file=sys.stderr)
            return 1
        for item in result.get("content", []):
            if item.get("type") == "text":
                print(item["text"])
        return 0
    except TimeoutError as exc:
        print(f"mcp_call: {exc}", file=sys.stderr)
        return 2
    except (RuntimeError, OSError) as exc:
        # OSError covers a server that died before reading (broken pipe).
        print(f"mcp_call: {exc}", file=sys.stderr)
        return 1
    finally:
        client.close()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
