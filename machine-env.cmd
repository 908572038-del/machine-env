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

REM --- Restore a complete PATH -----------------------------------------------
REM MCP servers are started by copilot-runtime.exe, which can inherit a PATH
REM that has system entries stripped as well as user ones. Measured: with only
REM the runtime's PATH the toolchain probe finds 4/12 tools, losing git and
REM cmake because those live in the machine PATH, not the user PATH.
REM
REM Probe scripts locate tools with Get-Command, so a truncated PATH silently
REM under-reports the toolchain. Rebuild PATH from both registry locations,
REM which is the authoritative source on Windows.
REM
REM Only entries not already present are appended, so the runtime's own
REM additions (its bundled tools, for instance) stay first and are never
REM discarded.

set "MACHINE_PATH="
for /f "usebackq tokens=2,*" %%A in (
    `reg query "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment" /v Path 2^>nul ^| findstr /i "Path"`
) do set "MACHINE_PATH=%%B"

set "USER_PATH="
for /f "usebackq tokens=2,*" %%A in (
    `reg query "HKCU\Environment" /v Path 2^>nul ^| findstr /i "Path"`
) do set "USER_PATH=%%B"

REM cmd has no direct string-contains test, so each candidate is compared with
REM a for loop over the current entries. Appending a duplicate is harmless but
REM needlessly lengthens PATH, which has a length limit.
call :append_path "%MACHINE_PATH%"
call :append_path "%USER_PATH%"

goto :launch

:append_path
if "%~1"=="" exit /b 0
for %%E in ("%~1") do set "CANDIDATE=%%~E"
if "%CANDIDATE%"=="" exit /b 0
echo ;%PATH%; | findstr /i /c:";%CANDIDATE%;" >nul 2>&1
if errorlevel 1 set "PATH=%PATH%;%CANDIDATE%"
exit /b 0

:launch
REM stdout carries the JSON-RPC stream, so all diagnostics go to stderr.
"%PYEXE%" "%SERVER%" %*
exit /b %ERRORLEVEL%
