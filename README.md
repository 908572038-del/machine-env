# machine-env-cpp MCP server

[![build](https://github.com/908572038-del/machine-env/actions/workflows/build.yml/badge.svg)](https://github.com/908572038-del/machine-env/actions/workflows/build.yml)
[![release](https://img.shields.io/github/v/release/908572038-del/machine-env)](https://github.com/908572038-del/machine-env/releases/latest)
[![license](https://img.shields.io/github/license/908572038-del/machine-env)](LICENSE)
[![platform](https://img.shields.io/badge/platform-Windows%20x64-blue)](https://github.com/908572038-del/machine-env/releases/latest)

A native Windows MCP server that answers two questions a coding agent cannot
answer cheaply by asking a shell: **where is the compiler**, and **what will break
this command**.

The first is not as obvious as it sounds. `cl.exe`, `ninja` and `msbuild` ship
inside Visual Studio and are not on `PATH`, so `where cl` finds nothing on a
machine with a complete C++ toolset installed. Listing everything on `PATH`
instead costs 716 entries and 10,940 characters to answer what a dozen lines can
say. This server probes the places a compiler actually lives and answers in
about 750 characters.

The second is what makes an answer usable: whether the shell is `cmd` or
PowerShell, whether `&&` works, whether elevation is needed, whether the code
page will mangle non-ASCII output, and whether a 5.1 execution policy will refuse
to run a script at all.

C++20, no runtime dependencies.

## Install

Download the portable ZIP from [Releases](https://github.com/908572038-del/machine-env/releases/latest),
extract, and run:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-portable.ps1
```

No Visual Studio, CMake, Ninja or NSIS needed. The `-setup.exe` in the same
release installs per-user with an uninstall entry in Apps & features instead.
Either way, restart the editor afterwards.

Other clients: `install-portable.ps1 -Client claude-desktop` (or `cursor`,
`windsurf`, `vscode`, `all`). `-ListClients` prints the config file each one uses.

## Tools

| Tool | Answers |
| --- | --- |
| `get_tools` | One line per developer tool: `cl C:\...\cl.exe`. Includes tools that ship inside Visual Studio or another install, which a bare name lookup misses. `name` narrows it |
| `get_system` | The five facts that change how a command must be written: shell and version, elevation, execution policy, code page, and tools that exist only on this process's PATH |

Both accept `refresh` to bypass the cache and `detail` for the full JSON.
`get_system` also accepts `measure_syntax` to parse shell constructs instead of
deriving their support from the version.

There were four tools. `get_apps` and `get_network` were removed in 0.6.0: an
installed-application inventory is shorter to ask the registry for than to
describe here, and HTTPS reachability is `curl -I`. Answering them cost more
context than the command it replaced. The server makes no outbound requests now.

## Reading an answer

`get_tools` prints an absolute path for every tool it finds. A path is usable
whether or not the tool is on `PATH`, so there is no "not on PATH" label: a
caller holding the path does not need to know whether the bare name would also
run. Absence is one line, not a list of everything missing.

Two fields decide how much an answer is worth:

- **`source`** on every capability: `measured` was observed by running a probe,
  `derived` follows from a version, `unknown` was not verified and must not be
  treated as support.
- **`_cache`** on every result: `answer` says where the data came from
  (`fresh`/`cache`/`shared`/`stale`) and `question` says why that rather than a
  new probe.

A missing tool means missing, not "probably there". A `WindowsApps` entry that is
a Store advert rather than an installed program is reported as missing, with the
reason, because running it only opens a shop page.

Shell syntax support (`&&`, here-strings, whether non-ASCII output survives a
pipe) is `derived` from the shell version by default, because starting Windows
PowerShell costs about 1.7s and that is most of the probe. Pass
`measure_syntax: true` to have each construct actually parsed instead.

## Privacy

Results contain the current user's profile paths and shell identity. The server
makes no network request. The raw Windows `MachineGuid` is never reported:
`get_tools` identifies a machine with a derived id that answers "same machine or
not" without naming the installation.

Windows only. It uses Win32, the registry, CPUID and WinHTTP.

## Building

Requires Visual Studio with the C++ workload (a toolset that implements C++20),
CMake, and Ninja.

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\verify.ps1   # end-to-end check
```

See [docs/build.md](docs/build.md) for the installer, the portable package, and
what each script does.

## Design notes

See [docs/design.md](docs/design.md) for the cache layout, the concurrency model,
and the measurements behind them.

## Layout

```text
src/main.cpp         MCP stdio protocol and native self-test
src/machine.cpp      Win32 probes, HTTPS checks, and cache
src/json.hpp         Self-contained JSON parser/serializer
src/version.hpp.in   Version, generated from CMakeLists.txt
docs/                Build and design notes
scripts/             Build, install, packaging, and uninstall
```

## Licence

MIT. See [LICENSE](LICENSE).