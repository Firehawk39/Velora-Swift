#!/usr/bin/env python3
"""
Velora MCP Bridge
Connects Antigravity, Claude, Cursor, and external AI agents directly to the Velora iOS App over MCP (JSON-RPC 2.0).

Usage:
    python velora_mcp_bridge.py --url http://192.168.1.50:8765/mcp
    or via environment variable:
    VELORA_URL=http://192.168.1.50:8765/mcp python velora_mcp_bridge.py
"""

import sys
import json
import os
import argparse
import urllib.request
import urllib.error

DEFAULT_URL = os.environ.get("VELORA_URL", "http://127.0.0.1:8765/mcp")

def send_to_velora(payload: dict, server_url: str) -> dict:
    try:
        data = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(
            server_url,
            data=data,
            headers={"Content-Type": "application/json"}
        )
        with urllib.request.urlopen(req, timeout=10.0) as resp:
            resp_data = resp.read()
            return json.loads(resp_data.decode("utf-8"))
    except Exception as e:
        return {
            "jsonrpc": "2.0",
            "id": payload.get("id"),
            "error": {
                "code": -32000,
                "message": f"Failed to connect to Velora app at {server_url}: {str(e)}"
            }
        }

def main():
    parser = argparse.ArgumentParser(description="Velora MCP Stdio Bridge")
    parser.add_argument("--url", default=DEFAULT_URL, help="Velora MCP Server HTTP URL (e.g. http://<phone-ip>:8765/mcp)")
    args = parser.parse_args()

    # Read JSON-RPC lines from stdin
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
            resp = send_to_velora(req, args.url)
            sys.stdout.write(json.dumps(resp) + "\n")
            sys.stdout.flush()
        except json.JSONDecodeError:
            err_resp = {
                "jsonrpc": "2.0",
                "id": None,
                "error": {"code": -32700, "message": "Parse error"}
            }
            sys.stdout.write(json.dumps(err_resp) + "\n")
            sys.stdout.flush()

if __name__ == "__main__":
    main()
