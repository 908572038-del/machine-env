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
disturbed. Most of it feeds the server a file and closes the pipe, which cannot
tell "answers" apart from "answers once the input ends", so a separate live
session keeps stdin open and requires each answer to come back while it is still
open — that is the case a real client is in, and the one a blocking block read
used to hang.

`install.ps1` accepts `-SkipBuild` to reuse an existing `build\machine-env-cpp.exe`
instead of rebuilding, which keeps re-installs and verification quick.

`install.ps1` registers one client by default and takes `-Client` to pick another:
`copilot` (default), `claude-desktop`, `cursor`, `windsurf`, `vscode`, or `all`.
`-ListClients` prints the supported names with the exact configuration file each
one uses, so there is no guessing about which path or top-level key applies.
Each client stores servers differently, and the difference is a silent failure
rather than an error: VS Code reads `servers` while the others read
`mcpServers`, and VS Code also ignores an `env` block it was not asked for.
`scripts\client-registry.ps1` is the single source for those layouts; the
installers, the portable scripts, and the NSIS package all read it instead of
each carrying their own copy.

`CMakeLists.txt` defines the C++17 target and Windows system libraries.
`build.ps1` locates Visual Studio and Ninja, configures/builds with CMake,
produces `build\machine-env-cpp.exe`, and runs its native self-test. `install.ps1`
copies the server to `%LOCALAPPDATA%\Programs\machine-env-cpp` and updates the
global Copilot MCP configuration by default, preserving other servers and
backing up the prior configuration. It refuses to overwrite malformed JSON. It
then starts the configured executable, performs the MCP handshake, lists tools,
and calls the hardware tool over stdio.

`package-portable.ps1` creates `build\release\machine-env-cpp-windows-x64.zip`.
After downloading and extracting the ZIP, run `install-portable.ps1`; it installs
the server per-user and registers its actual path globally, so no source path or
manual JSON editing is needed. It takes the same `-Client` and `-ListClients`
arguments as `install.ps1`, and the ZIP carries `client-registry.ps1` so the
client list is read from the same place as in a source checkout. The portable
install does not require Visual Studio, CMake, Ninja, or NSIS. When
`COPILOT_HOME` is set, the Copilot entry is written there; otherwise it uses
`~\.copilot\mcp-config.json`.

The MCP config points to the executable in the per-user install directory, not
to the source checkout or extracted ZIP directory.

Installers write nothing to the harness instruction folders. The rule reaches
every session through the `initialize` result, so the VS Code Local agent and
Agent Host sessions both receive it from the server itself instead of from a file
each harness would have to be given separately. NSIS uninstall and
`uninstall-portable.ps1` remove this server's MCP entry, leaving other servers
and instruction files untouched.

Tool calls return concise text **and** a structured body. The text is what a
model reads; `structuredContent` is what a caller acts on; both describe the
same result, so a caller no longer has to request `detail` just to parse an
answer (or pay for the full payload in the transcript just to read one).
`detail: true` still switches the text itself to the full JSON. Every result
also carries `_meta` with `tool`, `elapsed_ms`, `brief_payload_bytes` (the size
of the text the model ingests), and `cache_hit` when a cache was consulted,
which is where call-level measurements live so they never mix into the probed
facts. Each tool description restates the read-only constraint, so a harness
that does not inject `initialize.instructions` still sees it.

Requests are dispatched concurrently and answered by `id`, which is how JSON-RPC
2.0 correlates them. A client that pipelines calls pays for the slowest probe
instead of the sum of all of them (measured: a burst of four calls went from 5.6s
to 2.6s). Answers are emitted in request order while every earlier request can
still complete promptly, but a finished answer is not held indefinitely behind a
call that has genuinely stalled: once it has waited longer than the reorder window
(default 200 ms, set by `MACHINE_ENV_REORDER_WINDOW_MS`, range 0–2000), it is
emitted ahead of the missing earlier response, so one slow call cannot add its full
latency to every answer behind it. Responses are matched to requests by `id`; a
client that needs strictly in-order emission sets `MACHINE_ENV_REORDER_WINDOW_MS=0`
in the environment the server is started with — nothing sets it per client today, so
the window is on unless it was set explicitly. If per-client installs ever write it,
the rule is to write it only on an explicit signal that a client reads responses
positionally, and to fall back to `0` when unsure: guessing "positional" merely
forgoes the ordering optimization, whereas guessing "non-positional" for a client
that cannot match by `id` would corrupt correlation. Emitting out of order is legal
JSON-RPC 2.0, and reading responses positionally without checking `id` is relying on
behaviour the protocol does not promise. Request execution is concurrent, so the
order in which calls complete is not a promise either. Calls that depend on each
other must be sent in separate rounds — wait for one batch's responses before
sending the next — rather than batched together on the assumption that they run in
request order. The tools only read the environment and never change the system, but
that is not the same as having no ordering dependency: `get_network` with
`refresh: true` writes the cache, and a concurrent non-refresh call can read the
entry from before that refresh, so a refresh-then-read pair must be split into
separate rounds like any other dependency.
This section must stay in step with the concurrency note in `initialize.instructions`;
change both together.

`get_tools` reports each detected
tool on its own line in a fixed order, as `NAME = PATH`, with the version
appended when versions were asked for and could be read, a `不在PATH` marker
when it was found outside PATH, and a `与PYTHON不同源` marker when `pip` belongs
to a different Python installation than the reported `python`. The `不在PATH`
marker means the file was located and PATH simply has no directory for it — the
usual case for `cl`, `msbuild`, `signtool` and friends, which need a developer
prompt or an absolute path — so a footnote spells that out rather than leaving a
bare label to be read as "not installed". `python` itself is resolved by asking
PATH first, because the question is which interpreter the bare name runs: reading
an install directory first reported a second copy that PATH never reaches, and
then flagged the pip beside the *first* copy as belonging elsewhere. Reading a version
means running the tool, so it is opt-in through `include_versions: true`; without
it the answer is a filesystem lookup that starts no process, and the summary says
so rather than leaving a missing version to be read as an unknown one. Versions
are cached in an entry of their own, so the fast answer is never served to a
caller who asked for them and is never invalidated by one. Its `name` argument
narrows the answer, so a single
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
inventory is long and mostly noise. `limit` and `offset` page through the
matches: `count` stays the size of the inventory, and `page` records the window
this answer covers (`offset`, `returned`, `available`), so a page is never read
as the whole. Both filters take comma-separated
alternatives, and spaces inside one alternative are part of the phrase, so
`"visual studio"` does not also match a publisher named `... Studios`.

Concise summaries append their cache status when it matters: a cached result
shows its age in the largest unit that still reads at a glance (`23 分钟前`, not
`1390 秒前`) and names the way to get a live one (`refresh: true`), because an
answer that silently arrives from cache is easily mistaken for a fresh probe.
The operating system caption is derived from the build number, so
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
version whenever the legacy shell can be found and queried. All of those facts
come from a single shell invocation — version, edition, host, execution policy,
and the capability probes are answered by one script that tags each line — and
the legacy version is queried in parallel when both shells exist, so the answer
costs two processes at most instead of four in sequence. The preference is a
choice of shell to probe, not a detection of the terminal a caller is using.

`build-installer.ps1` creates `build\installer\machine-env-cpp-setup.exe`
using NSIS. The installer is per-user, includes the prebuilt server and the
client registry, registers an uninstaller, and adds the MCP entry to the user's
Copilot configuration. It registers Copilot because that is the only client it
can verify unattended; run `install.ps1 -Client all` after installing to add the
others. Uninstalling removes only the MCP entry that points to that installation
and preserves other servers and configuration fields. Close the editor before
upgrading an installation that is currently running, then reload it after
installing or uninstalling to refresh its server list.

## Cache and latency

The tool and application inventories are cached for 24 hours. System facts and
network state are cached for 10 minutes. Cache files live under the current
user's `%LOCALAPPDATA%\machine-env\cache`; writes are atomic and protected by a
named Windows mutex. Entries are invalidated when the server executable
changes — an entry records the binary's fingerprint, so an upgrade re-probes
instead of answering from a snapshot taken by a different build — or when their
TTL expires. A cached answer is therefore never one the previous build measured
under different rules. Cache failures do not prevent probes from
returning results. PATH results contain existing directories only; file paths
and nonexistent entries are omitted and counted.

The cache mutex is held for at most two seconds, and only for a **write**: reads
take no lock at all, because a write publishes by renaming a temporary file over
the destination, so a reader sees either the previous complete entry or the new
one and never a half-written file; the checksum then rejects anything that was
truncated or mixed by another writer. A write that cannot take the lock is
skipped and reported as `not_cached_because: "cache busy"` rather than blocking,
because freezing every instance behind one stuck writer is worse than
re-probing.

`refresh` is coalesced rather than taken literally. A refresh that arrives within
five seconds of a completed probe of the same kind is answered from that entry and
says so (`_cache.reason: "refresh coalesced"`), so a client cannot make the server
re-probe by asking twice. Across processes, one probe per kind is elected through a
named lock, so five editors opening at once cost one probe instead of five. Waiting
for that lock is bounded: a stalled holder costs a duplicate probe, never the
answer. A partial result (one that ran out of its budget) is never served as a
refresh and never stored.

Probes that start child processes kill the whole tree on timeout through a job
object, so a grandchild cannot outlive the timeout and hold the output pipe
open. `get_system` reports `process_tree_kill` as `job`, or `fallback` when the
job object was unavailable and only the direct child could be terminated.

Registry work is done once per question rather than once per lookup. A toolchain
probe reads the PATH value from the registry a single time and answers every
lookup from that snapshot (registry opens for one probe: 113 before, 3 now),
while an application inventory opens each application's key once instead of once
per field (667 before, 336 now — one per entry), which cut `get_apps` cold time by
about a fifth. The snapshot lasts exactly one probe: nothing is cached across
requests, so `refresh` still sees a PATH edited a moment ago.

Requests are read in 64 KB blocks instead of one byte at a time, which is what
makes receiving a large message cheap (rejecting a 9 MB message went from ~330ms
to ~2ms). The block read asks for whatever is already on the pipe and returns as
soon as one byte arrives: `istream::read` returns only when the buffer is full or
the input has ended, so against a client that keeps stdin open it would sit in
the call forever and the handshake would time out while stderr still said "server
ready". The 8 MiB limit still applies while reading: bytes past it are consumed
and counted but never stored, so an oversized message is refused without being
held in memory, and the next message on the stream is still read correctly.

`get_network` uses HTTPS HEAD requests to GitHub, Hugging Face, and PyPI, and
reports a reason such as `dns`, `connect`, `timeout`, or `tls` when a target is
unreachable. The four hosts are checked concurrently, so the call costs the
slowest endpoint rather than their sum. It is the only tool that opens a socket,
so a local system probe can never cause an unexpected outbound request.

A host blackholed at the resolver can stall past every per-phase WinHTTP
timeout, which no timeout setting can bound. The call is therefore capped by a
wall-clock budget: `timeout_ms` (200-10000, default 2500) is the deadline for the
whole check, and an endpoint still unanswered at the deadline is reported as
`timed_out` with `reason: "budget"` rather than being waited out. That is a third
answer, distinct from unreachable: the host was asked and did not answer in time.
`budget_ms` and `budget_exhausted` appear on the result so a partial answer is
never mistaken for a complete one. A probe that ran out of budget is returned but
never cached, so a timeout cannot be served as a fact for the next ten minutes.
Pass a larger `timeout_ms` for a slow link; a cached answer is always a complete
one, so a budgeted caller is still served from the cache. Raising the budget does
not, however, turn an unreachable host into a reachable one — each endpoint carries
its own WinHTTP timeouts, so past roughly 4.8 s the answer becomes `timed_out`
instead of `budget_exhausted` without changing whether the host answers at all.

`offline: true` skips every endpoint and reports each one as skipped without
opening a socket; `skip_endpoints` names individual hosts (`github_api`,
`github_raw`, `huggingface`, `pypi`) to leave unprobed. Both bypass the cache
because they change what the result means, and both keep "deliberately not
checked" distinct from "checked and unreachable".

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
  client-registry.ps1  Per-client config path, top-level key, and entry shape
  machine-env-cpp.nsi  NSIS installer definition
```
