"""MCP server exposing this machine's environment to AI agents.

Design principles
-----------------
1. The AI talks to tools, never to the probe scripts. Scripts live under
   ../probes and ../native and are invoked read-only; the agent has no path to
   edit them, so a bad guess cannot corrupt the measurement logic.
2. Observations are cached per machine (keyed on MachineGuid) with a content
   fingerprint. A hit is ~10ms; a miss costs seconds of subprocess work on
   low-end hardware. `refresh_env` forces a re-probe.
3. Every probe failure degrades to a structured error instead of crashing the
   server, so a missing compiler never takes the whole tool surface down.

Run standalone for a smoke test:  python server.py --selftest
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

try:
    # mcp 2.x renamed FastMCP -> MCPServer. mcp 1.x used
    # `from mcp.server.fastmcp import FastMCP`, so support both.
    from mcp.server.mcpserver import MCPServer as _ServerClass
except ImportError:  # pragma: no cover - mcp 1.x fallback
    try:
        from mcp.server.fastmcp import FastMCP as _ServerClass
    except ImportError:
        sys.stderr.write(
            "The 'mcp' package is required. Install with:\n"
            f'  "{sys.executable}" -m pip install "mcp>=1.2"\n'
        )
        raise

ROOT = Path(__file__).resolve().parent
PROBES = ROOT / "probes"
NATIVE_BIN = ROOT / "native" / "build" / "probe_hw.exe"
CACHE_DIR = ROOT / "cache"

# Cache lifetime. Hardware and toolchain change rarely; network reachability
# changes often, so it gets its own shorter window.
DEFAULT_TTL_SECONDS = 24 * 60 * 60
NETWORK_TTL_SECONDS = 10 * 60

mcp = _ServerClass(
    "machine-env",
    version="0.1.0",
    instructions=(
        "Observed facts about this machine: CPU ISA capabilities, toolchain paths, "
        "OS/shell/network state. Prefer these tools over re-deriving environment "
        "details with ad-hoc terminal commands."
    ),
)


# --------------------------------------------------------------------------- #
# process helpers
# --------------------------------------------------------------------------- #

def _run(cmd: list[str], timeout: int = 120) -> tuple[bool, str, str, int]:
    """Run a subprocess, returning (ok, stdout, stderr, elapsed_ms).

    Never raises: a probe crash must not take down the tool call.
    """
    started = time.perf_counter()
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
        )
        elapsed = int((time.perf_counter() - started) * 1000)
        return proc.returncode == 0, proc.stdout.strip(), proc.stderr.strip(), elapsed
    except subprocess.TimeoutExpired:
        elapsed = int((time.perf_counter() - started) * 1000)
        return False, "", f"timeout after {timeout}s", elapsed
    except FileNotFoundError as exc:
        elapsed = int((time.perf_counter() - started) * 1000)
        return False, "", f"not found: {exc}", elapsed
    except OSError as exc:
        elapsed = int((time.perf_counter() - started) * 1000)
        return False, "", f"OS error: {exc}", elapsed


_GUID_CACHE: str | None = None


def _machine_guid() -> str:
    """Stable per-installation id so caches never leak between machines.

    Memoised in-process: shelling out to PowerShell costs ~550ms on this class
    of CPU, and this is called on every cache read. The registry is also read
    directly when possible, which is far cheaper than spawning a shell.
    """
    global _GUID_CACHE
    if _GUID_CACHE is not None:
        return _GUID_CACHE

    if platform.system() == "Windows":
        # Direct registry read first: no subprocess, no shell startup.
        try:
            import winreg  # noqa: PLC0415 - Windows-only, kept local

            with winreg.OpenKey(
                winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\Microsoft\Cryptography"
            ) as key:
                value, _ = winreg.QueryValueEx(key, "MachineGuid")
                if value:
                    _GUID_CACHE = str(value).strip()
                    return _GUID_CACHE
        except (ImportError, OSError):
            pass

        # Registry blocked (policy, WOW64 redirection): fall back to a shell.
        ok, out, _, _ = _run(
            [
                "powershell", "-NoProfile", "-NonInteractive", "-Command",
                "(Get-ItemProperty 'HKLM:\\SOFTWARE\\Microsoft\\Cryptography').MachineGuid",
            ],
            timeout=30,
        )
        if ok and out:
            _GUID_CACHE = out.strip()
            return _GUID_CACHE

    # Last resort: still machine-specific, just weaker than a real GUID.
    _GUID_CACHE = hashlib.sha256(
        f"{platform.node()}|{platform.machine()}|{platform.system()}".encode()
    ).hexdigest()[:32]
    return _GUID_CACHE


_FP_CACHE: str | None = None


def _fingerprint() -> str:
    """Hash of the probe sources.

    Editing a script invalidates every cache entry automatically, so a fix can
    never be masked by a stale result. Memoised per process: the sources do not
    change while the server runs, and re-hashing on every cache read is waste.
    """
    global _FP_CACHE
    if _FP_CACHE is not None:
        return _FP_CACHE

    h = hashlib.sha256()
    for folder in (PROBES, ROOT / "native"):
        if not folder.exists():
            continue
        for path in sorted(folder.rglob("*")):
            if path.is_file() and path.suffix in {".ps1", ".cpp", ".py"}:
                h.update(path.name.encode())
                h.update(path.read_bytes())
    _FP_CACHE = h.hexdigest()[:16]
    return _FP_CACHE


# --------------------------------------------------------------------------- #
# cache
# --------------------------------------------------------------------------- #

def _cache_paths(kind: str) -> tuple[Path, Path]:
    guid = _machine_guid()
    stem = f"{kind}.{guid}"
    return CACHE_DIR / f"{stem}.json", CACHE_DIR / f"{stem}.meta.json"


def _read_cache(kind: str, ttl: int) -> tuple[dict[str, Any] | None, dict[str, Any]]:
    """Return (payload_or_None, meta). meta always describes why."""
    data_file, meta_file = _cache_paths(kind)
    meta: dict[str, Any] = {"hit": False, "reason": "no cache file"}

    if not data_file.exists() or not meta_file.exists():
        return None, meta

    try:
        stored = json.loads(meta_file.read_text(encoding="utf-8-sig"))
    except (OSError, json.JSONDecodeError) as exc:
        meta["reason"] = f"meta unreadable: {exc}"
        return None, meta

    meta["cached_at"] = stored.get("cached_at")
    meta["age_seconds"] = int(time.time() - stored.get("cached_at", 0))

    if stored.get("fingerprint") != _fingerprint():
        meta["reason"] = "probe sources changed"
        return None, meta

    if meta["age_seconds"] > ttl:
        meta["reason"] = f"expired (ttl {ttl}s)"
        return None, meta

    try:
        payload = json.loads(data_file.read_text(encoding="utf-8-sig"))
    except (OSError, json.JSONDecodeError) as exc:
        meta["reason"] = f"payload unreadable: {exc}"
        return None, meta

    meta["hit"] = True
    meta["reason"] = "fresh"
    return payload, meta


def _write_cache(kind: str, payload: dict[str, Any]) -> None:
    data_file, meta_file = _cache_paths(kind)
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    tmp_data = data_file.with_suffix(".json.tmp")
    tmp_meta = meta_file.with_suffix(".json.tmp")
    # Write via temp files so a crash mid-write cannot leave a half-JSON cache
    # that would poison every later read.
    tmp_data.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    tmp_meta.write_text(
        json.dumps(
            {
                "cached_at": int(time.time()),
                "fingerprint": _fingerprint(),
                "machine_guid": _machine_guid(),
            },
            indent=2,
        ),
        encoding="utf-8",
    )
    tmp_data.replace(data_file)
    tmp_meta.replace(meta_file)


# --------------------------------------------------------------------------- #
# probes
# --------------------------------------------------------------------------- #

def probe_hardware() -> dict[str, Any]:
    """CPUID-backed hardware facts. Falls back to WMI if the exe is missing."""
    if not NATIVE_BIN.exists():
        build = ROOT / "native" / "build.ps1"
        return {
            "error": "probe_hw.exe not built",
            "hint": f'Run: powershell -ExecutionPolicy Bypass -File "{build}"',
        }

    ok, out, err, ms = _run([str(NATIVE_BIN)], timeout=60)
    if not ok:
        return {"error": "probe_hw.exe failed", "stderr": err}

    try:
        data = json.loads(out)
    except json.JSONDecodeError as exc:
        return {"error": f"invalid JSON from probe_hw.exe: {exc}", "raw": out[:500]}

    data["_probe_ms"] = ms
    # Attach memory facts, which the CPUID probe cannot see. Flagged as coming
    # from WMI because its CPU fields are unreliable even though these are fine.
    ok2, out2, _, _ = _run(
        [
            "powershell", "-NoProfile", "-NonInteractive", "-Command",
            "$o=Get-CimInstance Win32_OperatingSystem;"
            "$c=Get-CimInstance Win32_ComputerSystem;"
            "[ordered]@{"
            " total_mem_mb=[math]::Round($o.TotalVisibleMemorySize/1024);"
            " free_mem_mb=[math]::Round($o.FreePhysicalMemory/1024);"
            " logical_cpu=$c.NumberOfLogicalProcessors"
            "} | ConvertTo-Json -Compress",
        ],
        timeout=60,
    )
    if ok2 and out2:
        try:
            mem = json.loads(out2)
            data["memory"] = mem
            data["memory_source"] = "WMI"
        except json.JSONDecodeError:
            pass
    return data


def probe_toolchain() -> dict[str, Any]:
    script = PROBES / "probe_toolchain.ps1"
    if not script.exists():
        return {"error": f"missing probe script: {script}"}
    ok, out, err, ms = _run(
        [
            "powershell", "-NoProfile", "-NonInteractive",
            "-ExecutionPolicy", "Bypass", "-File", str(script),
        ],
        timeout=180,
    )
    if not ok:
        return {"error": "probe_toolchain.ps1 failed", "stderr": err[:1000]}
    try:
        data = json.loads(out)
    except json.JSONDecodeError as exc:
        return {"error": f"invalid JSON: {exc}", "raw": out[:500]}
    data["_probe_ms"] = ms
    return data


def probe_environment(*, include_network: bool = True) -> dict[str, Any]:
    script = PROBES / "probe_environment.ps1"
    if not script.exists():
        return {"error": f"missing probe script: {script}"}
    ok, out, err, ms = _run(
        [
            "powershell", "-NoProfile", "-NonInteractive",
            "-ExecutionPolicy", "Bypass", "-File", str(script),
        ],
        timeout=180,
    )
    if not ok:
        return {"error": "probe_environment.ps1 failed", "stderr": err[:1000]}
    try:
        data = json.loads(out)
    except json.JSONDecodeError as exc:
        return {"error": f"invalid JSON: {exc}", "raw": out[:500]}
    if not include_network:
        data.pop("network", None)
    data["_probe_ms"] = ms
    return data


def _is_cacheable(kind: str, payload: dict[str, Any]) -> tuple[bool, str]:
    """Decide whether a probe result is worth persisting.

    A probe can succeed yet return a degraded result — for example the
    toolchain sweep run while its script was being overwritten returned 4/12
    tools with no `error` key. Caching that pinned the bad answer for the whole
    TTL, and the cache looked healthy because the fingerprint still matched.
    """
    if "error" in payload:
        return False, payload["error"]

    if kind == "hardware":
        # A real CPUID probe always reports a brand and an ISA table.
        if not payload.get("brand") or not payload.get("isa"):
            return False, "missing brand or isa"
        return True, ""

    if kind == "toolchain":
        found = payload.get("tool_count")
        total = payload.get("tool_total")
        if not isinstance(found, int) or not isinstance(total, int) or total <= 0:
            return False, "missing tool counts"
        # Python is the floor: without it nothing else in this project runs, and
        # its absence means the sweep ran in a broken environment.
        if "python" not in (payload.get("tools") or {}):
            return False, "python not found — probe ran in a broken environment"
        # vswhere only returns empty when the sweep ran in a degraded
        # environment. A machine with Visual Studio installed always resolves
        # it, and this machine has it, so an empty value means the sweep was
        # incomplete rather than that no compiler exists.
        if not payload.get("vs_path"):
            return False, "vs_path empty — vswhere did not resolve"
        return True, ""

    if kind == "environment":
        if not payload.get("os") or not payload.get("paths"):
            return False, "missing os or paths"
        return True, ""

    return True, ""


def _cached(kind: str, probe, ttl: int = DEFAULT_TTL_SECONDS) -> dict[str, Any]:
    payload, meta = _read_cache(kind, ttl)
    if payload is not None:
        payload["_cache"] = meta
        return payload
    fresh = probe()
    cacheable, reason = _is_cacheable(kind, fresh)
    if cacheable:
        _write_cache(kind, fresh)
    else:
        # Surface why the result is not persisted, so a degraded probe is
        # visible rather than silently repeated on every call.
        fresh.setdefault("_cache", {})
        fresh["_cache"]["cached"] = False
        fresh["_cache"]["not_cached_because"] = reason
    fresh["_cache"] = meta | fresh.get("_cache", {})
    return fresh


# --------------------------------------------------------------------------- #
# tools exposed to the agent
# --------------------------------------------------------------------------- #

@mcp.tool()
def get_hardware(refresh: bool = False) -> dict[str, Any]:
    """CPU identity, ISA capabilities (AVX/AVX2/VNNI/AVX-512), XCR0 state and RAM.

    ISA facts come from a CPUID probe, not WMI: Win32_Processor.Flags is
    truncated and under-reports AVX2. Use this before choosing a SIMD kernel,
    a quantization format, or a build target.
    """
    if refresh:
        fresh = probe_hardware()
        if _is_cacheable("hardware", fresh)[0]:
            _write_cache("hardware", fresh)
        return fresh
    return _cached("hardware", probe_hardware)


@mcp.tool()
def get_toolchain(refresh: bool = False) -> dict[str, Any]:
    """Locate compilers, interpreters and build tools (python, cl, ninja, git, ...).

    Returns absolute paths plus versions, which tools are missing, and which
    were found outside PATH (cl and ninja on this machine). Use before invoking
    a compiler or a build system.
    """
    if refresh:
        fresh = probe_toolchain()
        if _is_cacheable("toolchain", fresh)[0]:
            _write_cache("toolchain", fresh)
        return fresh
    return _cached("toolchain", probe_toolchain)


@mcp.tool()
def get_environment(refresh: bool = False) -> dict[str, Any]:
    """OS build, memory, shell capabilities, home paths and network reachability.

    Network results have a short TTL (10 min) because reachability changes far
    more often than hardware or toolchain.
    """
    if refresh:
        fresh = probe_environment()
        if _is_cacheable("environment", fresh)[0]:
            _write_cache("environment", fresh)
        return fresh
    return _cached("environment", probe_environment, ttl=NETWORK_TTL_SECONDS)


@mcp.tool()
def refresh_env(scope: str = "all") -> dict[str, Any]:
    """Force a re-probe, bypassing the cache.

    scope: "all", "hardware", "toolchain" or "environment".
    """
    valid = {"all", "hardware", "toolchain", "environment"}
    if scope not in valid:
        return {"error": f"invalid scope {scope!r}", "valid": sorted(valid)}

    out: dict[str, Any] = {"scope": scope, "refreshed": []}
    if scope in ("all", "hardware"):
        r = probe_hardware()
        if _is_cacheable("hardware", r)[0]:
            _write_cache("hardware", r)
            out["refreshed"].append("hardware")
        out["hardware"] = r
    if scope in ("all", "toolchain"):
        r = probe_toolchain()
        if _is_cacheable("toolchain", r)[0]:
            _write_cache("toolchain", r)
            out["refreshed"].append("toolchain")
        out["toolchain"] = r
    if scope in ("all", "environment"):
        r = probe_environment()
        if _is_cacheable("environment", r)[0]:
            _write_cache("environment", r)
            out["refreshed"].append("environment")
        out["environment"] = r
    return out


@mcp.tool()
def get_cache_status() -> dict[str, Any]:
    """Report cache freshness per category, so a caller can decide to refresh."""
    fp = _fingerprint()
    out: dict[str, Any] = {"fingerprint": fp, "categories": {}}
    for kind, ttl in (
        ("hardware", DEFAULT_TTL_SECONDS),
        ("toolchain", DEFAULT_TTL_SECONDS),
        ("environment", NETWORK_TTL_SECONDS),
    ):
        _, meta = _read_cache(kind, ttl)
        meta["ttl_seconds"] = ttl
        out["categories"][kind] = meta
    return out


# --------------------------------------------------------------------------- #
# entry points
# --------------------------------------------------------------------------- #

def _selftest() -> int:
    """Exercise every tool once. Used to verify the install end to end."""
    print(f"python     : {sys.version.split()[0]} ({sys.executable})")
    print(f"root       : {ROOT}")
    print(f"fingerprint: {_fingerprint()}")
    print(f"machine    : {_machine_guid()}")
    print()

    failures = 0
    for name, call in (
        ("get_cache_status", lambda: get_cache_status()),
        ("get_hardware", lambda: get_hardware()),
        ("get_toolchain", lambda: get_toolchain()),
        ("get_environment", lambda: get_environment()),
    ):
        started = time.perf_counter()
        try:
            result = call()
        except Exception as exc:  # noqa: BLE001 - selftest reports, never hides
            print(f"[FAIL] {name}: {type(exc).__name__}: {exc}")
            failures += 1
            continue
        elapsed = int((time.perf_counter() - started) * 1000)
        if isinstance(result, dict) and "error" in result:
            print(f"[FAIL] {name}: {result['error']}")
            failures += 1
            continue
        cache = result.get("_cache", {}).get("hit") if isinstance(result, dict) else None
        tag = "cache" if cache else "probe"
        print(f"[ OK ] {name:<18} {elapsed:>6} ms  ({tag})")

    # Second pass proves the cache actually short-circuits.
    print()
    print("--- cached pass ---")
    for name, call in (
        ("get_hardware", lambda: get_hardware()),
        ("get_toolchain", lambda: get_toolchain()),
        ("get_environment", lambda: get_environment()),
    ):
        started = time.perf_counter()
        result = call()
        elapsed = int((time.perf_counter() - started) * 1000)
        hit = result.get("_cache", {}).get("hit")
        print(f"[{'cache' if hit else 'probe':>5}] {name:<18} {elapsed:>6} ms")

    print()
    print("FAILURES:" if failures else "all tools OK", failures if failures else "")
    return 1 if failures else 0


def main() -> None:
    parser = argparse.ArgumentParser(description="machine-env MCP server")
    parser.add_argument(
        "--selftest",
        action="store_true",
        help="run every tool once and print timings, then exit",
    )
    args = parser.parse_args()

    if args.selftest:
        raise SystemExit(_selftest())

    # stdio is the default and the only transport VS Code needs here. Logs go to
    # stderr because stdout carries the JSON-RPC stream.
    print(f"machine-env MCP server ready (fingerprint {_fingerprint()})", file=sys.stderr)
    mcp.run()


if __name__ == "__main__":
    main()
