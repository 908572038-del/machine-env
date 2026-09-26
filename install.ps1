# install.ps1 — one-time setup for the machine-env MCP server.
#
# Idempotent: safe to re-run after `git pull`.
#
# What it does:
#   1. Checks for a usable Python (the Microsoft Store stub does not count).
#   2. Installs the `mcp` package if missing.
#   3. Builds the native CPUID probe if it is missing or out of date.
#   4. Writes the MCP configuration, using the launcher so the entry is
#      machine-independent and safe to sync.
#   5. Runs an end-to-end verification.

$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Root

function Write-Step([string]$Text) { Write-Host "`n== $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text)   { Write-Host "   OK  $Text" -ForegroundColor Green }
function Write-Warn2([string]$Text) { Write-Host "   !!  $Text" -ForegroundColor Yellow }
function Write-Err([string]$Text)  { Write-Host "   XX  $Text" -ForegroundColor Red }

# --------------------------------------------------------------------------- #
Write-Step 'Locating Python'

function Resolve-Python {
    # py.exe resolves real installations and ignores the Store stub.
    $candidates = @()
    if ($env:MACHINE_ENV_PYTHON) { $candidates += $env:MACHINE_ENV_PYTHON }
    if (Test-Path "$env:SystemRoot\py.exe") { $candidates += "$env:SystemRoot\py.exe" }
    $onPath = Get-Command python -ErrorAction SilentlyContinue
    if ($onPath) { $candidates += $onPath.Source }

    foreach ($c in $candidates) {
        try {
            $exe = & $c -c "import sys; print(sys.executable)" 2>$null
            if (-not $exe) { continue }
            $exe = $exe.Trim()
            # The Store stub lives under WindowsApps and cannot import packages.
            if ($exe -like '*\WindowsApps\*') {
                Write-Warn2 "skipping Store stub: $exe"
                continue
            }
            return @{ Launcher = $c; Exe = $exe }
        } catch { continue }
    }
    return $null
}

$py = Resolve-Python
if (-not $py) {
    Write-Err 'No usable Python found.'
    Write-Host '   Install Python 3.10+ from https://python.org, or set MACHINE_ENV_PYTHON.'
    exit 1
}
Write-Ok "interpreter : $($py.Exe)"
Write-Ok "via         : $($py.Launcher)"

# --------------------------------------------------------------------------- #
Write-Step 'Checking the mcp package'

& $py.Launcher -c "import mcp" 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host '   installing mcp...'
    & $py.Launcher -m pip install --quiet "mcp>=1.2"
    if ($LASTEXITCODE -ne 0) {
        Write-Err 'pip install failed.'
        exit 1
    }
}
$mcpVer = (& $py.Launcher -c "import mcp; print(getattr(mcp,'__version__','?'))" 2>$null).Trim()
Write-Ok "mcp $mcpVer"

# --------------------------------------------------------------------------- #
Write-Step 'Building the native CPUID probe'

$bin = Join-Path $Root 'native\build\probe_hw.exe'
$src = Join-Path $Root 'native\probe_hw.cpp'
$needsBuild = -not (Test-Path $bin)
if (-not $needsBuild) {
    # Rebuild when the source is newer than the binary.
    $needsBuild = (Get-Item $src).LastWriteTime -gt (Get-Item $bin).LastWriteTime
}

if ($needsBuild) {
    Write-Host '   compiling...'
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'native\build.ps1') | Out-Null
    if (-not (Test-Path $bin)) {
        Write-Err 'Build failed. get_hardware will report an error until this is fixed.'
        Write-Host '   Needs Visual Studio with the C++ workload.'
    } else {
        Write-Ok 'probe_hw.exe built'
    }
} else {
    Write-Ok 'probe_hw.exe is up to date'
}

# --------------------------------------------------------------------------- #
Write-Step 'Writing MCP configuration'

# The `command` is the launcher next to this script, so the entry contains no
# machine-specific paths and can be synced across devices as-is.
$launcher = Join-Path $Root 'machine-env.cmd'
if (-not (Test-Path $launcher)) {
    Write-Err "launcher missing: $launcher"
    exit 1
}

$config = [ordered]@{
    mcpServers = [ordered]@{
        'machine-env' = [ordered]@{
            type    = 'stdio'
            command = $launcher
            env     = [ordered]@{
                PYTHONUTF8     = '1'
                PYTHONUNBUFFERED = '1'
            }
        }
    }
}

$targets = @(
    (Join-Path $env:USERPROFILE '.copilot\mcp-config.json')
)
# The VS Code profile location is only written when one already exists, so this
# script never invents configuration for a setup the user does not have.

foreach ($t in $targets) {
    $dir = Split-Path -Parent $t
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    # Merge rather than overwrite: other MCP servers must survive a reinstall.
    $existing = $null
    if (Test-Path $t) {
        try { $existing = Get-Content $t -Raw | ConvertFrom-Json } catch { $existing = $null }
        if ($existing) {
            Copy-Item $t "$t.bak" -Force
        }
    }

    if ($existing -and $existing.mcpServers) {
        $existing.mcpServers | Add-Member -NotePropertyName 'machine-env' `
            -NotePropertyValue $config.mcpServers.'machine-env' -Force
        $merged = [ordered]@{ mcpServers = $existing.mcpServers }
        if ($existing.PSObject.Properties.Name -contains 'inputs') {
            $merged['inputs'] = $existing.inputs
        }
        $json = $merged | ConvertTo-Json -Depth 10
    } else {
        $json = $config | ConvertTo-Json -Depth 10
    }

    # Write without a BOM: JSON parsers reject a leading BOM, and
    # Set-Content -Encoding UTF8 emits one on Windows PowerShell.
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($t, $json, $utf8NoBom)
    Write-Ok "wrote $t"
    if (Test-Path "$t.bak") { Write-Host "        previous version saved as $t.bak" }
}

# --------------------------------------------------------------------------- #
Write-Step 'Verifying end to end'

# Invoke through cmd so the launcher itself is exercised, not just the script.
# stderr is merged deliberately: the server logs its startup line there, so a
# native-command failure must be judged by the exit code, not by output noise.
$verify = Join-Path $Root 'verify_config.py'
$out = & $py.Exe $verify 2>&1
$verifyExit = $LASTEXITCODE
$out | Where-Object {
    $_ -notmatch 'NativeCommandError|CategoryInfo|FullyQualifiedErrorId|^\+ |^At line'
}

Write-Host ''
if ($verifyExit -eq 0) {
    Write-Host 'INSTALL COMPLETE' -ForegroundColor Green
    Write-Host 'The machine-env tools appear in new chat sessions.'
} else {
    Write-Warn2 "verification exited $verifyExit — inspect the output above."
}

exit $verifyExit
