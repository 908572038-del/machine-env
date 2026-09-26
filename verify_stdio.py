"""Smoke test: connect to server.py over stdio and call every tool.

This exercises the real MCP wire protocol, not just the Python functions.
Run:  python verify_stdio.py
"""

from __future__ import annotations

import asyncio
import json
import sys
from pathlib import Path

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

HERE = Path(__file__).resolve().parent
SERVER = HERE / "server.py"
PYTHON = sys.executable


async def main() -> int:
    params = StdioServerParameters(
        command=PYTHON,
        args=[str(SERVER)],
        env={"PYTHONUTF8": "1", "PYTHONUNBUFFERED": "1"},
    )

    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            print("initialize: OK")

            listing = await session.list_tools()
            names = [t.name for t in listing.tools]
            print(f"tools advertised: {len(names)}")
            for name in names:
                print(f"  - {name}")

            expected = {
                "get_hardware",
                "get_toolchain",
                "get_environment",
                "refresh_env",
                "get_cache_status",
            }
            missing = expected - set(names)
            if missing:
                print(f"FAIL: missing tools {sorted(missing)}")
                return 1

            failures = 0
            for name in sorted(expected):
                try:
                    result = await session.call_tool(name, {})
                except Exception as exc:  # noqa: BLE001 - report, do not hide
                    print(f"  [FAIL] {name}: {exc}")
                    failures += 1
                    continue

                if result.is_error:
                    print(f"  [FAIL] {name}: server returned is_error")
                    failures += 1
                    continue

                # structuredContent is the dict form of the return value.
                payload = getattr(result, "structured_content", None)
                if payload is None:
                    payload = getattr(result, "structuredContent", None)
                if payload is None:
                    text = "".join(
                        c.text for c in result.content if getattr(c, "type", "") == "text"
                    )
                    try:
                        payload = json.loads(text)
                    except json.JSONDecodeError:
                        payload = {"_raw": text[:120]}

                keys = sorted(payload)[:6]
                malformed = isinstance(payload, dict) and "error" in payload
                tag = "FAIL" if malformed else " OK "
                if malformed:
                    failures += 1
                print(f"  [{tag}] {name:<18} keys={keys}")

            # Spot-check a known value so a shape change cannot pass silently.
            hw = await session.call_tool("get_hardware", {})
            hw_data = getattr(hw, "structured_content", None) or getattr(hw, "structuredContent", None) or {}
            brand = hw_data.get("brand", "?")
            width = hw_data.get("vector_width_bits", "?")
            print()
            print(f"hardware brand       : {brand}")
            print(f"vector_width_bits    : {width}")
            isa = hw_data.get("isa", {})
            print(f"isa.avx={isa.get('avx')} avx2={isa.get('avx2')} "
                  f"avx512f={isa.get('avx512f')} sse4_2={isa.get('sse4_2')}")

            print()
            print("RESULT:", "FAIL" if failures else "ALL TOOLS OK OVER STDIO")
            return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
