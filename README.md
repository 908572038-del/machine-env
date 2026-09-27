# machine-env-cpp MCP server

A native Windows MCP server that reports observed machine facts to coding
agents: CPU instruction-set support, installed developer tools, Windows and
shell details, filesystem paths, and optional network reachability.

The MCP server and probes are implemented in C++17. The PowerShell scripts are
used as Windows build/setup glue. Tool discovery covers common language
runtimes, compilers, build systems, JavaScript package managers, container and
WSL commands, editors, Windows package managers, archive utilities, installer
builders, and Windows SDK packaging tools.

## Tools

| Tool | Purpose |
| --- | --- |
| `get_hardware` | CPUID/XCR0-backed CPU capabilities and memory |
| `get_toolchain` | Locate developer, build, archive, and installer tools |
| `get_environment` | Windows, shell and existing PATH directories; `include_network=false` skips HTTPS checks |
| `refresh_env` | Force probes for `all`, `hardware`, `toolchain`, or `environment` |
| `get_cache_status` | Report cache freshness and invalidation per category |

This MCP is a pure probe: it reports what is present (tool names, versions,
paths, and PATH status) with no usage guidance or documentation URLs, so its
output stays compact and low-noise for agents.

The server uses a native CPUID probe and Windows APIs. AVX-family flags are
reported only when the operating system enables the corresponding XCR0 state.
WMI is not used for CPU capabilities.

## Build and install

Requirements: Windows x64 and Visual Studio with the C++ workload.
Building from source also requires CMake and Ninja. End users can use the
per-user desktop installer without installing the C++ build tools.

```powershell
powershell -ExecutionPolicy Bypass -File .\build.ps1
powershell -ExecutionPolicy Bypass -File .\install.ps1
powershell -ExecutionPolicy Bypass -File .\build-installer.ps1
```

`CMakeLists.txt` defines the C++17 target and Windows system libraries.
`build.ps1` locates Visual Studio and Ninja, configures/builds with CMake,
produces `build\machine-env-cpp.exe`, and runs its native self-test. `install.ps1` updates
`~\.copilot\mcp-config.json`, preserving other servers and backing up the prior
configuration. It refuses to overwrite malformed JSON. It then starts the
configured executable, performs the MCP handshake, lists tools, and calls the
hardware tool over stdio.

The MCP config points directly to the native executable.

Tool calls return concise text only by default. `get_toolchain` reports each
detected tool on its own line in a fixed order, as `NAME = PATH`, with the
version appended when known and a `不在PATH` marker when it was found outside
PATH. Missing tools are omitted from both concise and detailed toolchain
results.
Pass `detail: true` to `get_hardware`, `get_toolchain`, `get_environment`,
`refresh_env`, or `get_cache_status` to receive the full JSON data, including
cache metadata and detailed CPU/environment fields.

The server instructions ask AI clients to inspect project files before deciding
which tools are needed and not to download, install, or run installers unless
the user explicitly requests or approves it. Documentation links are for
learning tool usage, not prompts to install a tool.

`get_environment` reports the shell a terminal actually runs. When `pwsh` is
installed it is probed as the primary shell, so `ps_version`,
`supports_ampersand_ampersand`, and `has_heredoc` describe PowerShell 7+ rather
than the legacy `powershell.exe`; `shell_path` and `shell_kind` identify which
one was used, and `windows_powershell_version` records the legacy version
whenever the legacy shell can be found and queried. Without `pwsh`,
`powershell.exe` is used as before.

`build-installer.ps1` creates `build\installer\machine-env-cpp-setup.exe`
using NSIS. The installer is per-user, includes the prebuilt server, registers
an uninstaller, and adds the MCP entry to the user's Copilot configuration.
Uninstalling removes only the MCP entry that points to that installation and
preserves other servers and configuration fields. Close VS Code before
upgrading an installation that is currently running, then reload VS Code after
installing or uninstalling to refresh its server list.

## Cache and latency

Hardware and toolchain observations are cached for 24 hours. OS, shell, paths,
and network state are cached for 10 minutes. Cache files live under the current
user's `%LOCALAPPDATA%\machine-env\cache`; writes are atomic and protected by a
named Windows mutex. Entries are invalidated when the server executable
changes or their TTL expires. Cache failures do not prevent probes from
returning results. Local-only environment snapshots use a separate cache entry
from snapshots that include network checks, so skipping network still allows
the local OS, shell, and PATH facts to be cached without misreporting freshness.
PATH results contain existing directories only; file paths and nonexistent
entries are omitted and counted.

Network checks use HTTPS HEAD requests to GitHub, Hugging Face, and PyPI. Use
`{"include_network":false}` for a local-only environment snapshot.

## Privacy and platform support

Environment results contain the current user's profile paths and shell
identity. Network checks disclose outbound connectivity to the listed service
hosts. Consider these machine details when sending tool results to remote
services. Use this MCP as the source of current machine facts rather than
keeping or injecting a static tool-path memory file.

Toolchain results identify the machine with a stable, derived `machine_id`
(plus the computer name) so shared accounts can tell machines apart; the raw
Windows `MachineGuid` is not exposed in summaries.

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
