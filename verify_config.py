"""Verify the installed MCP configuration end to end.

Reads ~/.copilot/mcp-config.json exactly as VS Code/Agent Host would, launches
the server over stdio with those exact settings, and exercises the protocol.

This is the check that matters before trusting the server in a real session:
it proves the config paths resolve and the handshake completes.

Run:  python verify_config.py
"""

from __future__ import annotations

import asyncio
import json
import sys
from pathlib import Path

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

CONFIG = Path.home() / ".copilot" / "mcp-config.json"
SERVER_KEY = "machine-env"


def _get(obj: object, *names: str):
    """Read the first present attribute.

    mcp 2.x renamed several result fields from camelCase to snake_case
    (serverInfo -> server_info, structuredContent -> structured_content), so
    look both up rather than pinning to one SDK major.
    """
    for name in names:
        value = getattr(obj, name, None)
        if value is not None:
            return value
    return None


async def main() -> int:
    if not CONFIG.exists():
        print(f"FAIL: {CONFIG} does not exist")
        return 1

    cfg = json.loads(CONFIG.read_text(encoding="utf-8-sig"))
    servers = cfg.get("mcpServers") or {}
    if SERVER_KEY not in servers:
        print(f"FAIL: no '{SERVER_KEY}' entry in {CONFIG}")
        print(f"      found: {sorted(servers)}")
        return 1

    spec = servers[SERVER_KEY]
    command = spec["command"]
    args = spec.get("args", [])

    print(f"config    : {CONFIG}")
    print(f"command   : {command}")
    print(f"args      : {args}")
    print(f"command ok: {Path(command).exists()}")
    print(f"target ok : {Path(args[0]).exists() if args else 'n/a'}")
    print()

    params = StdioServerParameters(
        command=command, args=args, env=spec.get("env")
    )

    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            init = await session.initialize()
            info = _get(init, "server_info", "serverInfo")
            proto = _get(init, "protocol_version", "protocolVersion")
            print(f"handshake : OK")
            print(f"server    : {info.name} v{info.version}")
            print(f"protocol  : {proto}")
            print()

            listing = await session.list_tools()
            print(f"tools     : {len(listing.tools)}")
            for tool in listing.tools:
                desc = (tool.description or "").split("\n")[0][:70]
                print(f"  - {tool.name:<18} {desc}")
            print()

            result = await session.call_tool("get_hardware", {})
            if _get(result, "is_error", "isError"):
                print("FAIL: get_hardware returned an error")
                return 1
            data = _get(result, "structured_content", "structuredContent") or {}
            cache = (data.get("_cache") or {}).get("reason", "?")
            print("smoke test: get_hardware")
            print(f"  brand  : {data.get('brand')}")
            print(f"  width  : {data.get('vector_width_bits')}")
            print(f"  cache  : {cache}")
            isa = data.get("isa", {})
            print(
                f"  isa    : sse4_2={isa.get('sse4_2')} avx={isa.get('avx')} "
                f"avx2={isa.get('avx2')} avx512f={isa.get('avx512f')}"
            )
            print()
            print("RESULT: CONFIG VERIFIED — server is usable from VS Code")
            return 0


if __name__ == "__main__":
    try:
        raise SystemExit(asyncio.run(main()))
    except KeyboardInterrupt:
        raise SystemExit(130)
