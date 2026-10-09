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
| `get_system` | Windows, CPUID/XCR0-backed hardware facts, shell, PATH, and machine policies. Local only; it never makes a network request |
| `get_tools` | Locate developer tools; `name` narrows the answer to the tools asked about, and a name the probe does not cover is looked up on PATH |
| `get_apps` | Installed applications from the uninstall registry, including software with no command-line entry point; `filter` selects entries, otherwise only the count is returned |
| `get_network` | GitHub, Hugging Face, and PyPI reachability; the only tool that makes outbound requests, and failures report a reason |

Every tool accepts `refresh` to bypass its cache and `detail` for the full JSON.
Capability fields report how the answer was obtained: `measured` was observed by
running a harmless probe, `derived` follows from a version, and `unknown` means
it was not verified and must not be read as support. Shell syntax support such as
`&&` and here-strings is decided by parsing the construct, and non-ASCII output
is checked by a round-trip, so the answer does not depend on trusting a version
string.

Uncertainty is always stated rather than smoothed over: an unexpandable
`REG_EXPAND_SZ` value counts as unknown instead of being reported as a literal
`%VAR%` path, a partial application inventory is flagged, and a binary whose own
hash cannot be computed never reuses a cached result.

A cache entry also carries a checksum over the facts it stores, so an entry that
was edited, truncated, or half-written by something else is discarded and
re-probed rather than served as fact. The guard detects corruption rather than
forgery: anything able to rewrite the file could recompute the checksum too, so
it is not a signature.

Facts that describe the session rather than the machine are recomputed on every
call, so a cached answer cannot go stale on them. Elevation is the current
example: the same machine answers differently depending on how the client was
started, so `is_admin` is checked live even when the rest of `get_system` is
served from cache.

This MCP is a pure probe: it reports what is present (tool names, versions,
paths, and PATH status) with no usage guidance or documentation URLs, so its
output stays compact and low-noise for agents.

The server uses a native CPUID probe and Windows APIs. AVX-family flags are
reported only when the operating system enables the corresponding XCR0 state.
WMI is not used for CPU capabilities.

Display adapters are read from the display class registry instead of
`Win32_VideoController`, whose `AdapterRAM` field is 32-bit and therefore
saturates: on one tested machine it reported 4 GB for a 24 GB card, while the
registry figure agreed exactly with what the vendor tooling reported for the
same adapter. Adapters with no hardware behind them, such as remote and
indirect display drivers, are listed but marked `virtual` so they are never
mistaken for compute that can be used.

Memory is reported as both physical and committed: `total_mem_mb` and
`free_mem_mb` describe RAM, while `commit_limit_mb` and `commit_available_mb`
describe what a reservation is charged against. The two can differ sharply when
the page file is small, and free physical memory alone does not answer whether
a large allocation will succeed.

Tool discovery and the reported PATH entries are read from the registry instead
of from the process environment, because the registry is what a newly started
shell inherits. The server's own copy was captured when it started, so a tool
installed and added to PATH afterwards would otherwise stay invisible to every
later probe, including one that asked to refresh. `path_source` records which of
the two was used, and `process_path_differs` reports whether they currently
disagree.

## Build and install

Requirements: Windows x64 and Visual Studio with the C++ workload.
Building from source also requires CMake and Ninja. End users can use the
per-user desktop installer without installing the C++ build tools.

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\install.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\build-installer.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\package-portable.ps1
```

`scripts\verify.ps1` is the one-command check: it builds, runs the native
self-test, installs into a throwaway profile, asserts that the install leaves no
instruction file behind and that the rule the server injects still carries its
obligations, asserts the protocol contract
(identity, the four tools, rejected unknown arguments, no undeclared
`resources/list`), then tampers with a cache entry to confirm it is rejected and
re-probed rather than served, then uninstalls and confirms nothing was left
behind. It only touches a temporary profile, so a real installation is never
disturbed.

`install.ps1` accepts `-SkipBuild` to reuse an existing `build\machine-env-cpp.exe`
instead of rebuilding, which keeps re-installs and verification quick.

`CMakeLists.txt` defines the C++17 target and Windows system libraries.
`build.ps1` locates Visual Studio and Ninja, configures/builds with CMake,
produces `build\machine-env-cpp.exe`, and runs its native self-test. `install.ps1`
copies the server to `%LOCALAPPDATA%\Programs\machine-env-cpp` and updates the
global Copilot MCP configuration, preserving other servers and backing up the
prior configuration. It refuses to overwrite malformed JSON. It then starts the
configured executable, performs the MCP handshake, lists tools, and calls the
hardware tool over stdio.

`package-portable.ps1` creates `build\release\machine-env-cpp-windows-x64.zip`.
After downloading and extracting the ZIP, run `install-portable.ps1`; it installs
the server per-user and registers its actual path globally, so no source path or
manual JSON editing is needed. The portable install does not require Visual
Studio, CMake, Ninja, or NSIS. When `COPILOT_HOME` is set, MCP configuration is
written there; otherwise it uses `~\.copilot\mcp-config.json`.

The MCP config points to the executable in the per-user install directory, not
to the source checkout or extracted ZIP directory.

Installers write nothing to the harness instruction folders. The rule reaches
every session through the `initialize` result, so the VS Code Local agent and
Agent Host sessions both receive it from the server itself instead of from a file
each harness would have to be given separately. NSIS uninstall and
`uninstall-portable.ps1` remove this server's MCP entry, leaving other servers
and instruction files untouched.

Tool calls return concise text only by default. `get_tools` reports each detected
tool on its own line in a fixed order, as `NAME = PATH`, with the version
appended when known, a `不在PATH` marker when it was found outside PATH, and a
`与PYTHON不同源` marker when `pip` belongs to a different Python installation
than the reported `python`. Its `name` argument narrows the answer, so a single
tool can be checked without paying for the whole list; it matches tool names
rather than paths, so asking for `cmake` does not also return `ninja` merely
because it lives under a `CMake` directory. A name the probed catalog does not
contain is looked up on PATH instead, so asking about a tool outside the catalog
answers with its path rather than with nothing, and a name that is not on PATH
says so. A filter that matches nothing says that too, rather than returning an
empty answer. Missing tools are omitted, but a tool whose version probe failed
is listed with a `版本未知` marker rather than being dropped, so a failed probe
is never read as a missing tool.
`get_apps` returns only a count unless `filter` is given, because the full
inventory is long and mostly noise. Both filters take comma-separated
alternatives, and spaces inside one alternative are part of the phrase, so
`"visual studio"` does not also match a publisher named `... Studios`.

Concise summaries append their cache status when it matters: a cached result
shows its age. The operating system caption is derived from the build number, so
Windows 11 is not reported with the legacy `Windows 10` registry product name.
Pass `detail: true` to any tool to receive the full JSON data, including cache
metadata and the detailed fields behind the summary.

The server returns its rule from `initialize`, so a client that injects server
instructions applies it without any file being loaded. That result is the only
route the rule takes, and `verify.ps1` asserts the injected text still carries
the obligations the rule exists for, so a truncated or emptied rule fails the
check. The rule installs nothing by itself: it only tells the agent to ask the
user before changing the machine.

`get_system` reports one shell and identifies which one it chose. `pwsh` is
preferred when it is installed, so `shell_path` and `shell_kind` are what tell a
caller which executable the probed values describe; the capability values
themselves live under `shell.capabilities` (`ampersand_ampersand`, `here_string`,
`non_ascii_pipe_utf8`), and `windows_powershell_version` records the legacy
version whenever the legacy shell can be found and queried. The preference is a
choice of shell to probe, not a detection of the terminal a caller is using.

`build-installer.ps1` creates `build\installer\machine-env-cpp-setup.exe`
using NSIS. The installer is per-user, includes the prebuilt server, registers
an uninstaller, and adds the MCP entry to the user's Copilot configuration.
Uninstalling removes only the MCP entry that points to that installation and
preserves other servers and configuration fields. Close VS Code before
upgrading an installation that is currently running, then reload VS Code after
installing or uninstalling to refresh its server list.

## Cache and latency

The tool and application inventories are cached for 24 hours. System facts and
network state are cached for 10 minutes. Cache files live under the current
user's `%LOCALAPPDATA%\machine-env\cache`; writes are atomic and protected by a
named Windows mutex. Entries are invalidated when the server executable
changes or their TTL expires. Cache failures do not prevent probes from
returning results. PATH results contain existing directories only; file paths
and nonexistent entries are omitted and counted.

`get_network` uses HTTPS HEAD requests to GitHub, Hugging Face, and PyPI, and
reports a reason such as `dns`, `connect`, `timeout`, or `tls` when a target is
unreachable. It is the only tool that opens a socket, so a local system probe
can never cause an unexpected outbound request.

## Privacy and platform support

Environment results contain the current user's profile paths and shell
identity. Network checks disclose outbound connectivity to the listed service
hosts. Consider these machine details when sending tool results to remote
services. Use this MCP as the source of current machine facts rather than
keeping or injecting a static tool-path memory file.

Toolchain results identify the machine with a stable, derived `machine_id`
(plus the computer name) so shared accounts can tell machines apart. The raw
Windows `MachineGuid` is not reported at all: it identifies the installation to
anything that reads it, and the derived id already answers whether two results
came from the same machine.

The implementation is Windows-specific: it uses Win32, registry, CPUID, and
WinHTTP APIs. Linux and macOS are not supported.

## Layout

```text
src/main.cpp         MCP stdio protocol and native self-test
src/machine.cpp      Win32 probes, HTTPS checks, and cache
src/json.hpp         Small self-contained JSON parser/serializer
CMakeLists.txt       C++ target, compiler settings, and Windows libraries
scripts/             Build, install, packaging, and uninstall scripts
  build.ps1            MSVC build and native self-test
  verify.ps1           Build, install, protocol, and uninstall check in one command
  install.ps1          Per-user install and MCP connection test
  build-installer.ps1  NSIS installer packaging
  package-portable.ps1 Portable ZIP packaging
  install-portable.ps1 One-file install from the extracted ZIP
  uninstall-portable.ps1 Removes the per-user install and its registration
  configure-mcp.ps1    Merges or removes the MCP entry
  machine-env-cpp.nsi  NSIS installer definition
```
