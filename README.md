# machine-env MCP server

A native Windows MCP server that reports observed machine facts to coding
agents: CPU instruction-set support, installed developer tools, Windows and
shell details, filesystem paths, and optional network reachability.

The MCP server and probes are implemented in C++17 with no Python runtime
dependency and no Python process invocation. The PowerShell scripts are Windows
build/setup glue only; Python may still appear as one of the discovered tools.

## Tools

| Tool | Purpose |
| --- | --- |
| `get_hardware` | CPUID/XCR0-backed CPU capabilities and memory |
| `get_toolchain` | Locate developer tools and report versions |
| `get_environment` | Windows, shell and paths; `include_network=false` skips HTTPS checks |
| `refresh_env` | Force probes for `all`, `hardware`, `toolchain`, or `environment` |
| `get_cache_status` | Report cache freshness and invalidation per category |

The server uses a native CPUID probe and Windows APIs. AVX-family flags are
reported only when the operating system enables the corresponding XCR0 state.
WMI is not used for CPU capabilities.

## Build and install

Requirements: Windows x64 and Visual Studio with the C++ workload.
The build also requires CMake; the installer checks for it before configuring
the native target.

```powershell
powershell -ExecutionPolicy Bypass -File .\build.ps1
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

`CMakeLists.txt` defines the C++17 target and Windows system libraries.
`build.ps1` locates Visual Studio and Ninja, configures/builds with CMake,
produces `build\machine-env.exe`, and runs its native self-test. `install.ps1` updates
`~\.copilot\mcp-config.json`, preserving other servers and backing up the prior
configuration. It refuses to overwrite malformed JSON. It then starts the
configured executable, performs the MCP handshake, lists tools, and calls the
hardware tool over stdio.

The MCP config points directly to the native executable; it needs no Python
path or Python environment variables.

## Cache and latency

Hardware and toolchain observations are cached for 24 hours. OS, shell, paths,
and network state are cached for 10 minutes. Cache files live under the current
user's `%LOCALAPPDATA%\machine-env\cache`; writes are atomic and protected by a
named Windows mutex. Entries are invalidated when the server executable
changes or their TTL expires. Cache failures do not prevent probes from
returning results.

Network checks use HTTPS HEAD requests to GitHub, Hugging Face, and PyPI. Use
`{"include_network":false}` for a local-only environment snapshot.

## Privacy and platform support

Environment results contain the current user's profile paths and shell
identity. Network checks disclose outbound connectivity to the listed service
hosts. Consider these machine details when sending tool results to remote
services.

The implementation is Windows-specific: it uses Win32, registry, CPUID, and
WinHTTP APIs. Linux and macOS are not supported.

## Layout

```text
src/main.cpp         MCP stdio protocol and native self-test
src/machine.cpp      Win32 probes, HTTPS checks, and cache
src/json.hpp         Small self-contained JSON parser/serializer
CMakeLists.txt       C++ target, compiler settings, and Windows libraries
build.ps1            MSVC build and native self-test
install.ps1          Configuration merge and MCP connection test
```
