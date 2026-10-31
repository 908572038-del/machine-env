# Changelog

Notable changes to machine-env-cpp. Versions follow the one in
`project(... VERSION ...)` and in `kServerVersion`, which `--version` reports.

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
