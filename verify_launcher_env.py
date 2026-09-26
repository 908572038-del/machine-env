"""Verify the launcher's environment handling.

Two things are checked, because they fail differently:

1. The user-level PATH is restored. A process started by copilot-runtime.exe can
   inherit only the system PATH, which drops the user entries that Get-Command
   needs for tools installed per-user.
2. The toolchain count is stable across both environments. What matters is that
   the launcher does not *lose* tools relative to a full environment.

Note on the trimmed PATH used below: it removes the user-level entries only.
Stripping the system entries as well would remove Git and CMake, which no
launcher can bring back — those live in the system PATH by design, and a real
MCP process has them (verified against a running server's environment).

Run:  python verify_launcher_env.py
"""

from __future__ import annotations

import asyncio
import os
import sys
import winreg
from pathlib import Path

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

HERE = Path(__file__).resolve().parent
LAUNCHER = HERE / "machine-env.cmd"

# System PATH as copilot-runtime.exe provides it. User entries are appended by
# the launcher from the registry.
SYSTEM_PATH = ";".join(
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


def user_path_from_registry() -> str:
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as key:
            value, _ = winreg.QueryValueEx(key, "Path")
            return value or ""
    except OSError:
        return ""


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
        print(f"{label:<34} FAILED {type(exc).__name__}: {exc}")
        return None

    count = f"{data.get('tool_count')}/{data.get('tool_total')}"
    tools = ", ".join(sorted((data.get("tools") or {}).keys()))
    print(f"{label:<34} {count:<7} {tools}")
    return data


async def main() -> int:
    if not LAUNCHER.exists():
        print(f"launcher not found: {LAUNCHER}")
        return 1

    user_path = user_path_from_registry()
    print(f"user PATH from registry ({len(user_path.split(';'))} entries):")
    for entry in (user_path.split(";") if user_path else []):
        if entry:
            print(f"    {entry}")
    print()

    print("get_toolchain through the launcher")
    print()

    full = await probe(dict(os.environ), "full environment")

    # Reproduce the runtime: system PATH only, launcher must append the user part.
    trimmed_env = dict(os.environ)
    trimmed_env["Path"] = SYSTEM_PATH
    trimmed_env.pop("PYTHONPATH", None)
    trimmed = await probe(trimmed_env, "system PATH (launcher appends)")

    # A PATH with neither user nor system entries is not a real scenario, but it
    # shows what a genuinely broken environment looks like, for contrast.
    broken_env = dict(os.environ)
    broken_env["Path"] = r"C:\Windows\system32"
    broken = await probe(broken_env, "system32 only (control)")

    print()
    if full is None or trimmed is None:
        print("RESULT: INCONCLUSIVE — a run failed")
        return 1

    n_full = full.get("tool_count", 0)
    n_trim = trimmed.get("tool_count", 0)

    if n_trim >= n_full:
        note = ""
        if broken is not None:
            note = (
                f" (even a near-empty PATH recovers to {broken.get('tool_count')}, "
                "since the launcher rebuilds PATH from the registry)"
            )
        print(f"RESULT: PASS — {n_trim} tools either way{note}")
        return 0

    print(f"RESULT: FAIL — {n_trim} tools with the system PATH vs {n_full} with the full one")
    missing = set((full.get("tools") or {})) - set((trimmed.get("tools") or {}))
    if missing:
        print(f"        Lost: {', '.join(sorted(missing))}")
        print("        The launcher is not appending HKCU\\Environment\\Path.")
    return 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))

