"""Verify the launcher restores the user-level PATH.

MCP servers are started by copilot-runtime.exe, which inherits only the system
PATH; user-level entries (Python, Git, CMake) are absent. Because the probe
scripts locate tools with Get-Command, a trimmed PATH makes the toolchain probe
under-report. This test reproduces that environment, starts the server through
the launcher exactly as VS Code does, and calls get_toolchain over MCP.

Run:  python verify_launcher_env.py
"""

from __future__ import annotations

import asyncio
import os
import sys
from pathlib import Path

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

HERE = Path(__file__).resolve().parent
LAUNCHER = HERE / "machine-env.cmd"

# A PATH resembling what copilot-runtime.exe provides: system directories only.
TRIMMED_PATH = ";".join(
    [
        r"C:\Windows\system32",
        r"C:\Windows",
        r"C:\Windows\System32\Wbem",
        r"C:\Windows\System32\WindowsPowerShell\v1.0",
        r"C:\Windows\System32\OpenSSH",
    ]
)


def _field(obj, *names):
    """mcp 2.x renamed result fields to snake_case; support both."""
    for name in names:
        value = getattr(obj, name, None)
        if value is not None:
            return value
    return None


async def probe(env: dict[str, str], label: str) -> dict | None:
    """Start the server through the launcher and call get_toolchain."""
    params = StdioServerParameters(command=str(LAUNCHER), args=[], env=env)
    try:
        async with stdio_client(params) as (read, write):
            async with ClientSession(read, write) as session:
                await session.initialize()
                result = await session.call_tool("get_toolchain", {"refresh": True})
                data = _field(result, "structured_content", "structuredContent") or {}
    except Exception as exc:  # noqa: BLE001 - report, do not hide
        print(f"{label:<26} FAILED {type(exc).__name__}: {exc}")
        return None

    count = f"{data.get('tool_count')}/{data.get('tool_total')}"
    tools = ", ".join(sorted((data.get("tools") or {}).keys()))
    print(f"{label:<26} {count:<7} {tools}")
    return data


async def main() -> int:
    if not LAUNCHER.exists():
        print(f"launcher not found: {LAUNCHER}")
        return 1

    print("get_toolchain through the launcher")
    print()

    # The launcher reads HKCU\Environment\Path, so the parent's PATH is what
    # varies between the two runs.
    full = await probe(dict(os.environ), "full environment")

    trimmed_env = dict(os.environ)
    trimmed_env["Path"] = TRIMMED_PATH
    trimmed_env.pop("PYTHONPATH", None)
    trimmed = await probe(trimmed_env, "trimmed PATH (no user)")

    print()
    if full is None or trimmed is None:
        print("RESULT: INCONCLUSIVE — a run failed")
        return 1

    n_full = full.get("tool_count", 0)
    n_trim = trimmed.get("tool_count", 0)

    if n_trim >= n_full:
        print(f"RESULT: PASS — launcher restores the user PATH ({n_trim} tools either way)")
        return 0

    print(f"RESULT: FAIL — trimmed yields {n_trim} tools vs {n_full} with the full PATH")
    missing = set((full.get("tools") or {})) - set((trimmed.get("tools") or {}))
    if missing:
        print(f"        Missing under trimmed PATH: {', '.join(sorted(missing))}")
    return 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
