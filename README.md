# machine-env — MCP server for this machine's environment

An MCP server that reports observed facts about the local machine: CPU ISA
capabilities, toolchain paths, OS/shell state and network reachability.

Agents call **tools**, never the probe scripts. The scripts stay behind the
server boundary, so an agent cannot edit the measurement logic by mistake.

## Why this exists

Three problems it solves:

1. **Wrong hardware facts.** `Win32_Processor.Flags` is truncated by WMI and
   under-reports AVX2. ISA capabilities must come from CPUID, and AVX support
   must additionally be gated on `XCR0` — a CPU can report AVX in CPUID while
   the OS never enables YMM state, which makes AVX unusable.
2. **Rediscovery cost.** Locating 12 tools plus Visual Studio takes seconds on
   low-end hardware. Results are cached per machine and invalidated by content
   fingerprint.
3. **Script fragility.** The probe scripts are not exposed as files an agent can
   edit. Fixes happen in this repository, under version control.

## Layout

```
mcp-machine-env/
├── server.py                     MCP server (protocol, caching, error handling)
├── machine-env.cmd               launcher: resolves Python and server.py at run time
├── install.ps1                   one-time setup, idempotent, safe to re-run
├── verify_stdio.py               end-to-end test over the real wire protocol
├── verify_config.py              test using the real installed MCP configuration
├── native/
│   ├── probe_hw.cpp              CPUID / XCR0 probe -> JSON on stdout
│   └── build.ps1                 MSVC build (sources vcvars in-process)
├── probes/
│   ├── probe_toolchain.ps1       locate compilers/interpreters/build tools
│   └── probe_environment.ps1     OS, shell, paths, network
├── cache/                        generated, gitignored, per-machine
└── mcp-config.example.json       template for the MCP configuration
```

## Install

The repository is public, so installation needs no credentials.

```powershell
$dst = "$env:USERPROFILE\.machine-env"
git clone --depth 1 https://github.com/908572038-del/machine-env.git $dst
powershell -ExecutionPolicy Bypass -File "$dst\install.ps1"
```

`install.ps1` is idempotent and does everything: finds a real Python (rejecting
the Microsoft Store stub), installs `mcp` if missing, builds the native probe,
merges the MCP entry into `~/.copilot/mcp-config.json` (backing up any previous
version), and verifies the result end to end.

The clone destination is arbitrary — `install.ps1` resolves its own location, so
the repository can live anywhere. `~/.machine-env` is only a convention.

Manual equivalent:

```powershell
py -m pip install "mcp>=1.2"
powershell -ExecutionPolicy Bypass -File native\build.ps1
py server.py --selftest      # tool logic + cache behaviour
py verify_config.py          # the configuration VS Code will actually read
```

### Automated install from an agent

`~/.copilot/instructions/本机环境.instructions.md` tells an agent to install this
server when its tools are missing: clone, run `install.ps1`, then tell the user
to start a new conversation. The last step is required — MCP configuration is
read at session start, so the current session cannot see newly registered tools.

## Configure VS Code

The Agent Host reads `~/.copilot/mcp-config.json` natively (portable format,
top-level `mcpServers`). For VS Code-profile based setups the equivalent is
`.vscode/mcp.json` with a top-level `servers` object — note the different key.

To sync this configuration across devices, enable **MCP Servers** in
`Settings Sync: Configure`.

### Why the config is machine-independent

The `command` points at `machine-env.cmd`, not at a Python interpreter. That
launcher resolves both the interpreter and `server.py` at run time:

| Order | Source | Why |
| ----- | ------ | --- |
| 1 | `%MACHINE_ENV_PYTHON%` | explicit override for unusual setups |
| 2 | `%SystemRoot%\py.exe` | Windows Python Launcher; stable path on every machine |
| 3 | `python.exe` on PATH | last resort; may be the Store stub |

This matters because `python` on PATH is frequently the Microsoft Store stub,
which resolves but cannot import site-packages. `py.exe` finds genuine
installations regardless of PATH.

`server.py` is located relative to the launcher, so the repository can live
anywhere — no absolute paths anywhere in the configuration, which is what makes
it safe to sync.

## Tools

| Tool | Returns |
| ---- | ------- |
| `get_hardware` | vendor, brand, family/model/stepping, XCR0, full ISA table, `vector_width_bits`, RAM |
| `get_toolchain` | absolute paths + versions for `python pip uv git node npm cargo go java cmake ninja cl`, which are missing, which are off-PATH |
| `get_environment` | OS build, memory, shell capabilities, home paths, network reachability |
| `refresh_env` | force re-probe; `scope` = `all` / `hardware` / `toolchain` / `environment` |
| `get_cache_status` | freshness and invalidation reason per category |

## Install

```powershell
# 1. dependencies
$py = "$env:LOCALAPPDATA\Python\pythoncore-3.14-64\python.exe"
& $py -m pip install "mcp>=1.2"

# 2. build the native probe (needs Visual Studio with C++ tools)
powershell -ExecutionPolicy Bypass -File native\build.ps1

# 3. verify end to end
& $py server.py --selftest      # tool logic + cache behaviour
& $py verify_stdio.py           # real MCP wire protocol
```

## Configure VS Code

The Agent Host reads `~/.copilot/mcp-config.json` natively (portable format,
top-level `mcpServers`). Copy `mcp-config.example.json` there and fix the two
absolute paths for the target machine.

For VS Code-profile based setups, the equivalent is `.vscode/mcp.json` with a
top-level `servers` object — note the different key.

To sync this configuration across devices, enable **MCP Servers** in
`Settings Sync: Configure`.

## Caching

Cache keys are `(category, MachineGuid)`, so entries never leak between
machines. Two invalidation rules apply:

- **Content fingerprint** — editing any `.ps1`, `.cpp` or `.py` under `probes/`
  or `native/` invalidates everything. A fix can never be masked by a stale hit.
- **TTL** — 24h for hardware and toolchain, 10min for network (reachability
  changes far more often than hardware).

Failed probes are never cached, so a transient error is not pinned for a full
day.

Cached reads are sub-millisecond; a cold toolchain probe is several seconds on
this class of CPU.

## Design notes

- **Degrade, never crash.** A missing compiler or an unbuilt native probe
  returns a structured `{"error": ..., "hint": ...}` instead of killing the
  server, so one broken probe cannot take down the rest.
- **No hardcoded paths.** Every path comes from `Get-Command`, an environment
  variable, or `vswhere`. The same code works on any Windows machine.
- **Store stub avoidance.** `WindowsApps\python.exe` is the Microsoft Store
  stub, not a real interpreter; real Python roots are prepended to `PATH`
  before probing so the stub never wins.
- **vswhere is a fallback, not the default.** It walks the installer registry
  and costs ~70ms, so it only runs when a tool is still missing after the
  `Get-Command` sweep.
- **Direct registry reads.** `MachineGuid` is read via `winreg`, not by
  spawning PowerShell, which saves ~550ms per call; the result is memoised.
- **WMI is trusted for memory only.** Its CPU fields are known to be
  unreliable, and the CPU path deliberately does not use them.
