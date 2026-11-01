# Changelog

Notable changes to machine-env-cpp. Versions follow the one in
`project(... VERSION ...)`, which is the only place the number is written: a
generated header carries it to `--version` and the fingerprint, and
`build-installer.ps1` passes it to NSIS.

## 0.5.0

An answer is only useful if the caller can act on it. These changes are about the
answers that were true but could not be acted on: a missing tool with no reason, a
PATH flag with no difference, a cache block whose three fields disagreed, and a
version list that made the caller read twelve paths to learn what can be built.

### Added

- `get_tools` starts with what the machine can actually do
  (`可用：C/C++ 编译器、构建工具、Git`), so the capability does not have to be
  reassembled from a dozen paths.
- `get_tools` reports `missing_reasons` beside the name for the absences that have
  one: `visual_studio` for tools that ship inside Visual Studio and need a
  developer prompt, `windows_alias` for a python App Execution Alias with no
  interpreter behind it, `user_install` for per-user tools that may belong to
  another account. A bare "not found" sent the caller to install something that
  was already there.
- `get_system` names the PATH entries that differ between the process copy and the
  system copy (`only_in_process`, `only_in_registry`, `order_differs`), because
  the flag alone required diffing two strings by hand. The probe searches the
  process copy, which is what the note says.

### Changed

- `_cache` answers two questions with two fields instead of asking a reader to
  reconcile three that could disagree. `cached: true`, `hit: false` and
  `reason: "server binary changed"` used to appear together. Now:
  `answer` is `fresh` | `cache` | `shared` | `stale`, and `question` says why that
  rather than a new probe. Storing is reported separately as `stored` /
  `not_stored_because`, because it describes the call and not the data.
- Cache metadata is no longer written into the entry. It became part of the stored
  bytes, so one call's `shared` label could be served to a later caller as a hit.
- The concise summaries say when an answer is stale and why, instead of reporting
  an old result as if it were current.

### Fixed

- Narrowing `get_tools` with `name` kept `missing_reasons` entries for tools the
  filter had removed.

## 0.4.1

Found by using the server for the work it exists for.

### Fixed

- `get_system` said "usable vector width: 128 bits" and stopped. That is the
  answer both for a CPU with no AVX and for one whose OS never enabled XSAVE, and
  those want different build flags. The summary now names the instruction set:
  `128 bits (no AVX)`.
- `get_network` told a caller already on an 8 s budget to pass 5 s. Past roughly
  4.8 s every endpoint hits its own per-phase timeout, so more budget cannot
  change the answer, and the note now says that.
- `get_tools` emitted `python_root: ""` when no interpreter was found, which
  reads as an answered field. It is now absent unless there is a path to report.
- `get_tools` answered two shapes for one fact: an absent catalogued tool
  vanished, while a name outside the catalog came back in `unresolved_tools`.
  Every requested name that resolved to nothing is now listed.
- `get_network` called a timeout "unreachable". WinHTTP 12002 means the request
  did not finish in time; the tally now counts it apart from hosts that answered.
## 0.4.0

### Added

- `.github/workflows/release.yml` publishes what a person actually installs from
  a `v*` tag: the portable ZIP, the desktop installer, the bare executable, and a
  `SHA256SUMS.txt`. It refuses a tag that does not match the project version,
  because a `v0.5.0` tag shipping a `0.4.0` binary is invisible until someone
  reads `--version` on a fresh install.
- LICENSE (MIT) and status badges for the build, the latest release, the licence
  and the platform. The repository had no licence, so the front page said "No
  license" and nothing granted anyone the right to use it.
- `docs/build.md` and `docs/design.md` hold the build walkthrough and the cache
  and concurrency design, so the README can stay a page a visitor reads.

### Changed

- The project is C++20, and CMake requires it: `CMAKE_CXX_STANDARD 20` with
  `CMAKE_CXX_STANDARD_REQUIRED ON`. There is no C++17 fallback, because two
  spellings of the same code would mean one of them is never compiled and never
  tested. A toolset without `<format>`, `<span>` or `<bit>` now fails to build
  instead of silently taking a different path.
- `/Zc:__cplusplus` is set for MSVC. Without it `__cplusplus` reports 199711L on
  every toolset, so a feature test written in the source answers about C++98.
- The version is written once, in `CMakeLists.txt`. `src/version.hpp.in` is
  generated from `project(... VERSION ...)` and every consumer reads it:
  `--version`, the source fingerprint, the portable package name, and
  `build-installer.ps1`, which passes it to NSIS so the uninstall entry names the
  server it actually contains.
- `get_system` starts no shell by default. The version, edition and host come
  from `HKLM\SOFTWARE\Microsoft\PowerShell\3\PowerShellEngine`, and the execution
  policy from the same registry tree. A cold probe went from 2.6s to 46ms on a
  Celeron N5095A, because starting Windows PowerShell costs about 1.7s before it
  runs a statement. The capability fields say `source: derived`;
  `measure_syntax: true` parses each construct and says `measured` instead, and
  the two answers are cached under separate keys.
- The README was cut from 465 lines to about 100. The build walkthrough and the
  cache design moved to `docs/`, where a reader who wants them can find them
  without scrolling past them.

### Fixed

- `get_tools` answered two ways for the same question. A catalogued tool that is
  not installed vanished from `tools` and appeared nowhere, so
  `name: "python, node"` returned an empty map with no explanation, while a name
  the catalog never heard of came back in `unresolved_tools`. Every requested
  name that resolved to nothing is now listed, whether or not the catalog covered
  it.
- `get_network` called a timeout "unreachable". WinHTTP 12002 means the request
  did not finish in time, and a larger budget might answer differently; that is a
  claim about the attempt, not about the host. An endpoint that ran out of time
  now says so, and the tally counts it apart: `3/4 reachable, 1 did not answer in
  time`, not `3/4`.
- A dead Windows Store alias was reported as an installed tool. `python3.exe`
  under `WindowsApps` is a zero-byte reparse point that only opens the Store, and
  `SearchPathW` returns it like any other executable. The reparse payload names
  the entry point behind the alias, and a live tool resolves to its own
  (`!winget`) while a Store advert resolves to `!PythonRedirector`, so only the
  redirector entries are dropped.
- The alias reader no longer walks a fixed buffer by hand. The reported bytes are
  held in a `std::span`, the tag is read with `std::bit_cast`, and the payload is
  split through a `std::wstring_view`.
- `install.ps1` and `install-portable.ps1` could not replace a server that was
  running, which is the normal state during an upgrade: a client holds it open
  for as long as the client is open. Windows will not let a running executable be
  overwritten but will let it be renamed, so the old copy is moved aside first.
- Uninstall left the portable scripts and its own binary behind.
- The packaging scripts only looked for `build\machine-env-cpp.exe`, which is
  where the Ninja build leaves it. CMake's Visual Studio generator writes
  `build\Release\`, so the scripts were unusable in exactly the CI job that
  needed them.
- The README's opening paragraph still claimed C++17 after the project moved.

### Fixed

- The `get_system` summary said "usable vector width: 128 bits" and stopped
  there. That is the answer both for a CPU with no AVX and for one whose OS never
  enabled XSAVE, and the two want different build flags -- so the line invites a
  wrong decision. It now says which: `128 bits (no AVX)`, or `AVX but not AVX2`.
- `get_network` told a caller on an 8 s budget to try 5 s. Past roughly 4.8 s each
  endpoint hits its own per-phase timeout, so more budget cannot change the
  answer; the note now says that instead of repeating advice already taken.
- `get_tools` emitted `python_root: ""` when no interpreter was found, which
  reads as an answered field. A caller cannot tell "no python" from "python
  exists but its directory could not be derived". The field is now absent unless
  there is a path to report.
### Internal

- Six `rfind(..., 0) == 0` calls became `starts_with`, written once in
  `machine.hpp` because `string_view` gains it in C++23 rather than C++20.
- `std::format` replaced the `ostringstream` and `to_string` concatenation used
  for machine ids, fingerprints, cache filenames, Windows error messages, and the
  synthesized application names in the self-test.
## 0.3.2

### Fixed

- `get_tools` reported a dead Windows Store app execution alias as an installed
  tool. `python3.exe` and `pip3.exe` live under `WindowsApps` as zero-byte
  reparse points, and `SearchPathW` returns them like any other executable, so
  the probe answered "found" for an interpreter that is not installed -- the
  alias only opens the Microsoft Store. `python` was the sole exception because
  it alone went through the WindowsApps check, which is why the two disagreed on
  the same machine.
- The file cannot settle the question: a live alias (`winget.exe`) and a dead one
  are byte-identical, both zero bytes with the same
  `IO_REPARSE_TAG_APPEXECLINK` tag. Only the reparse payload differs, naming the
  entry point behind the alias. A live tool resolves to its own entry point
  (`!winget`, `!App`); a Store advert resolves to `!PythonRedirector`, the shim
  whose purpose is to offer a download. `search_executable` now reads that
  payload and drops only the redirector entries, so `winget` and Windows Terminal
  keep working while dead aliases stop being reported.

### Changed

- `get_system` no longer starts a shell by default. The version, edition and
  host come from `HKLM\SOFTWARE\Microsoft\PowerShell\3\PowerShellEngine`, and
  the execution policy from the same registry tree, instead of from
  `$PSVersionTable` and `Get-ExecutionPolicy` inside a new process. Starting
  Windows PowerShell costs about 1.7s on a low-power machine before it runs a
  single statement, which made a cold system probe cost 2.6s; reading the
  registry makes it 46ms (measured on a Celeron N5095A, a 51x reduction).
- The capability fields (`ampersand_ampersand`, `here_string`,
  `non_ascii_pipe_utf8`) are therefore judged from the announced version and say
  `source: derived`. The rules are exact: `&&` and `||` arrived in PowerShell
  7.0, a here-string predates every supported version, and only the Desktop
  edition pipes through the console code page.
- `get_system` accepts `measure_syntax: true` to buy the measurement back. It
  starts the shell once, parses each construct, runs the non-ASCII round-trip,
  and reports `source: measured` with the shell's own version. The two answers
  are cached under separate keys (`system` and `system_measured`), so a derived
  result is never served to a caller who asked for a measurement.
- A derived probe can report a slightly older build than the shell prints,
  because the registry records the version at installation and Windows updates
  the files without rewriting it. Only the major version is compared, which is
  what every rule here depends on.
- The self-test asserts the alias classification on a live alias and that a real
  tool does not report the redirector entry point, so a regression fails the
  build rather than silently restoring the false positive.

### Added

- `.github/workflows/build.yml`: builds Release and Debug on `windows-2022`, runs
  the native self-test, then calls `get_tools` as a client would and asserts that
  every reported path exists and that a reported tool under `WindowsApps`
  actually runs.

## 0.3.1

The version this changelog starts from. Earlier history is in the commit log.
