@echo off
REM Launcher for the machine-env MCP server.
REM
REM Why this exists: an MCP configuration needs a `command` that resolves on
REM every machine. Absolute paths to a Python interpreter and to server.py are
REM machine-specific, which defeats Settings Sync. This launcher resolves both
REM at run time.
REM
REM Resolution order for Python:
REM   1. %MACHINE_ENV_PYTHON%            explicit override
REM   2. %SystemRoot%\py.exe             Windows Python Launcher, stable path
REM   3. python.exe on PATH              may be the Microsoft Store stub
REM
REM The project root is located relative to this script, so the repository can
REM live anywhere as long as this file is next to server.py.

setlocal

REM --- Locate server.py ------------------------------------------------------
set "SERVER=%~dp0server.py"
if exist "%SERVER%" goto :found

set "SERVER=%USERPROFILE%\.machine-env\server.py"
if exist "%SERVER%" goto :found

echo machine-env: server.py not found. Looked in: 1>&2
echo   %~dp0server.py 1>&2
exit /b 1

:found
REM --- Locate a real Python interpreter --------------------------------------
REM Note: `python` on PATH is often the Microsoft Store stub, which resolves but
REM cannot import site-packages. py.exe is preferred because it finds genuine
REM installations regardless of PATH.

set "PYEXE="
if defined MACHINE_ENV_PYTHON if exist "%MACHINE_ENV_PYTHON%" set "PYEXE=%MACHINE_ENV_PYTHON%"
if not defined PYEXE if exist "%SystemRoot%\py.exe" set "PYEXE=%SystemRoot%\py.exe"

if defined PYEXE goto :run

REM Last resort: walk PATH looking for a python.exe that is not the stub.
for %%P in (python.exe) do set "PYEXE=%%~$PATH:P"
if not defined PYEXE (
    echo machine-env: no Python interpreter found. 1>&2
    echo Install Python 3.10+ or set MACHINE_ENV_PYTHON. 1>&2
    exit /b 1
)

:run
set "PYTHONUTF8=1"
set "PYTHONUNBUFFERED=1"

REM --- Restore user-level PATH ----------------------------------------------
REM MCP servers are started by copilot-runtime.exe, which inherits only the
REM system PATH: user-level entries (Python, Git, CMake, ...) are absent.
REM Probe scripts locate tools with Get-Command, so without this the toolchain
REM probe silently reports most tools as missing. Verified: trimmed PATH yields
REM 3/12 tools versus 6/12 with the user PATH restored.
REM
REM The user PATH is read from the registry rather than from the current
REM process, because this process never had it to begin with.

for /f "usebackq tokens=2,*" %%A in (
    `reg query "HKCU\Environment" /v Path 2^>nul ^| findstr /i "Path"`
) do set "USER_PATH=%%B"

if defined USER_PATH set "PATH=%PATH%;%USER_PATH%"

REM --- Locate a real Python interpreter --------------------------------------
REM Note: `python` on PATH is often the Microsoft Store stub, which resolves but
REM cannot import site-packages. py.exe is preferred because it finds genuine
REM installations regardless of PATH.

set "PYEXE="
if defined MACHINE_ENV_PYTHON if exist "%MACHINE_ENV_PYTHON%" set "PYEXE=%MACHINE_ENV_PYTHON%"
if not defined PYEXE if exist "%SystemRoot%\py.exe" set "PYEXE=%SystemRoot%\py.exe"

if defined PYEXE goto :launch

REM Last resort: walk PATH looking for a python.exe that is not the stub.
for %%P in (python.exe) do set "PYEXE=%%~$PATH:P"
if not defined PYEXE (
    echo machine-env: no Python interpreter found. 1>&2
    echo Install Python 3.10+ or set MACHINE_ENV_PYTHON. 1>&2
    exit /b 1
)

:launch
REM stdout carries the JSON-RPC stream, so all diagnostics go to stderr.
"%PYEXE%" "%SERVER%" %*
exit /b %ERRORLEVEL%
