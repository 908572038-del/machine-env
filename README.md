# machine-env-cpp MCP server

[![build](https://github.com/908572038-del/machine-env/actions/workflows/build.yml/badge.svg)](https://github.com/908572038-del/machine-env/actions/workflows/build.yml)
[![release](https://img.shields.io/github/v/release/908572038-del/machine-env)](https://github.com/908572038-del/machine-env/releases/latest)
[![license](https://img.shields.io/github/license/908572038-del/machine-env)](LICENSE)
[![platform](https://img.shields.io/badge/platform-Windows%20x64-blue)](https://github.com/908572038-del/machine-env/releases/latest)

A native Windows MCP server that tells coding agents what this machine actually
has: CPU capabilities, installed developer tools, Windows and shell details,
PATH, and optional network reachability. C++20, no runtime dependencies.

It exists because an agent that guesses at a machine is wrong in ways nobody
notices until a build fails. Everything it reports was measured on the machine it
runs on, and every answer says how it was obtained.

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
| `get_system` | Windows, CPU (CPUID/XCR0), memory, GPU, shell, PATH, policies. Local only; never makes a network request |
| `get_tools` | Where a developer tool is. `name` narrows it; a name outside the catalog is looked up on PATH |
| `get_apps` | Installed applications from the uninstall registry, including software with no command line. `filter` selects; without it only the count is returned |
| `get_network` | GitHub, Hugging Face and PyPI reachability. The only tool that goes outbound, and a failure says why |

All four accept `refresh` to bypass the cache and `detail` for the full JSON.

## Reading an answer

Two fields decide how much an answer is worth:

- **`source`** on every capability: `measured` was observed by running a probe,
  `derived` follows from a version, `unknown` was not verified and must not be
  treated as support.
- **`_cache`** on every result: whether the answer is fresh, how old it is, and
  whether this call shared a probe another caller was already running.

A missing tool means missing, not "probably there". A path under `WindowsApps`
that turns out to be a Store advert rather than an installed program is reported
as missing, because that is what it is.

Shell syntax support (`&&`, here-strings, whether non-ASCII output survives a
pipe) is `derived` from the shell version by default, because starting Windows
PowerShell costs about 1.7s and that is most of the probe. Pass
`measure_syntax: true` to have each construct actually parsed instead.

## Privacy

Results contain the current user's profile paths and shell identity, and
`get_network` discloses outbound connectivity to the hosts it checks. The raw
Windows `MachineGuid` is never reported: `get_tools` identifies a machine with a
derived id that answers "same machine or not" without naming the installation.

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