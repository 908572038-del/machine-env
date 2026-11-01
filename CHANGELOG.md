# Changelog

Notable changes to machine-env-cpp. Versions follow the one in
`project(... VERSION ...)`, which is the only place the number is written: a
generated header carries it to `--version` and the fingerprint, and
`build-installer.ps1` passes it to NSIS.

## 0.4.0

### Added

- LICENSE (MIT) and status badges for the build, the latest release, the licence
  and the platform. The repository had no licence, so the front page said "No
  license" and nothing granted anyone the right to use it.

### Fixed

- The README's opening paragraph said the server is written in C++17, which
  stopped being true in a3e55c7. That line is what a reader checks to decide
  whether their toolset can build this.

### Added

- `.github/workflows/release.yml` publishes what a person actually installs from
  a `v*` tag: the portable ZIP, the desktop installer, the bare executable, and a
  `SHA256SUMS.txt`. It refuses a tag that does not match the project version,
  because a `v0.5.0` tag shipping a `0.4.0` binary is invisible until someone
  reads `--version` on a fresh install.
- The portable package and the installer are named after the version, so two
  downloads cannot be confused for each other.

### Changed

- The version is written once, in `CMakeLists.txt`. `src/version.hpp.in` is
  generated from `project(... VERSION ...)` and every consumer reads it:
  `--version`, the source fingerprint, the portable package name, and
  `build-installer.ps1`, which passes it to NSIS so the uninstall entry names the
  server it actually contains. Changing the version in one place now moves all of
  them -- verified by building 9.9.9 and watching `--version` follow.
- The project is now C++20, and CMake requires it: `CMAKE_CXX_STANDARD 20` with
  `CMAKE_CXX_STANDARD_REQUIRED ON`. There is no C++17 fallback, because two
  spellings of the same code would mean one of them is never compiled and never
  tested. A toolset without `<format>`, `<span>` or `<bit>` now fails to build
  instead of silently taking a different path.
- `/Zc:__cplusplus` is set for MSVC. Without it `__cplusplus` reports 199711L on
  every toolset, so a feature test written in the source would answer about
  C++98 and be wrong on a compiler that supports more.

### Fixed

- Reading an app execution alias no longer relies on pointer arithmetic over a
  fixed buffer. The bytes the kernel reported are held in a `std::span` and every
  read goes through it, the tag is read with `std::bit_cast` instead of a
  `reinterpret_cast` to a misaligned `uint32_t*`, and the payload is split on NUL
  through a `std::wstring_view` rather than by advancing an offset by hand.
  Behaviour is unchanged -- the values it returns were checked field by field
  against 0.3.2 -- but the bound now lives in one place instead of in each loop
  condition.
- The redirector test compares the application name rather than searching the
  whole entry point. An entry point is `<package>!<application>`, so a package
  whose name contained the shim would have matched before.

### Internal

- `starts_with` replaces six `rfind(..., 0) == 0` calls. `std::string_view` gains
  it in C++23, not C++20, so it is one constexpr function in `machine.hpp` rather
  than an index search written out at each site.
- `std::format` replaces the `std::ostringstream` and `std::to_string`
  concatenation used for machine identifiers, fingerprints, cache filenames,
  Windows error messages and the synthesized application names in the self-test.
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
