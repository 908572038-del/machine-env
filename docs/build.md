# Building and installing

[Back to the README](../README.md)

Requirements: Windows x64 and Visual Studio with the C++ workload, and a
toolset that implements C++20: the code uses <format>, <span>, <bit> and
concepts directly, and CMake requires the standard rather than falling back to
C++17. MSVC gets /Zc:__cplusplus, without which __cplusplus reports 199711L
and a feature test in the source would answer about C++98.
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

`CMakeLists.txt` defines the C++20 target and Windows system libraries.
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
version whenever the legacy shell can be found and queried. The preference is a
choice of shell to probe, not a detection of the terminal a caller is using.

A default probe starts no shell at all. The version, edition and host come from
`HKLM\SOFTWARE\Microsoft\PowerShell\3\PowerShellEngine`, which is what the
installer recorded, and the execution policy from the same registry tree; the
capability fields are then decided from those values and say `source: derived`.
That matters because starting Windows PowerShell costs about 1.7s on a low-power
machine before it runs a single statement: reading the registry turned a 2.6s
system probe into 46ms (measured on a Celeron N5095A). `measure_syntax: true`
buys the measurement back: it starts the shell once, parses `&&` and a
here-string, runs the non-ASCII round-trip, and reports `source: measured`
together with the shell's own version rather than the recorded one. The two
answers are cached under separate keys, so a derived result is never served to a
caller who asked for a measurement. The engine key records the version at
installation and Windows updates the files without rewriting it, which is why a
derived probe can report a slightly older build: only the major version is
compared, and that is what every rule here depends on.

`build-installer.ps1` creates `build\installer\machine-env-cpp-setup.exe`
using NSIS. The installer is per-user, includes the prebuilt server and the
client registry, registers an uninstaller, and adds the MCP entry to the user's
Copilot configuration. It registers Copilot because that is the only client it
can verify unattended; run `install.ps1 -Client all` after installing to add the
others. Uninstalling removes only the MCP entry that points to that installation
and preserves other servers and configuration fields. Close the editor before
upgrading an installation that is currently running, then reload it after
installing or uninstalling to refresh its server list.
