# probe_toolchain.ps1 — locate compilers, runtimes and build tools; emit JSON.
#
# Design notes:
#   * Nothing is hardcoded. Every path comes from Get-Command or an environment
#     variable, so the same script is valid on any Windows machine.
#   * Get-Command is run for all tools first, then vswhere is consulted only for
#     the tools that are still missing. vswhere itself is slow (it walks the
#     installer registry), so it must not run unconditionally.
#   * WindowsApps\python.exe is the Microsoft Store stub, not a real
#     interpreter. Real Python directories are prepended to PATH before probing
#     so the stub never wins.
#   * Output is one JSON object. Diagnostics go to stderr so stdout stays clean.

$ErrorActionPreference = 'SilentlyContinue'

$TOOLS = @(
    'python', 'pip', 'uv', 'git', 'node', 'npm',
    'cargo', 'go', 'java', 'cmake', 'ninja', 'cl'
)

function Get-PythonRoot {
    # Prefer real installs over the Store stub.
    $roots = @(
        "$env:LOCALAPPDATA\Python",
        "$env:LOCALAPPDATA\Programs\Python",
        "$env:USERPROFILE\anaconda3",
        "$env:USERPROFILE\miniconda3",
        "$env:LOCALAPPDATA\anaconda3",
        "$env:LOCALAPPDATA\miniconda3"
    )
    foreach ($r in $roots) {
        if (Test-Path "$r\python.exe") { return $r }
        $child = Get-ChildItem $r -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'pythoncore|Python\d+' } |
            Select-Object -First 1
        if ($child) { return $child.FullName }
    }
    return $null
}

function Get-VsPath {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) { return $null }
    $p = & $vswhere -latest -property installationPath 2>$null
    if ($p) { return $p.Trim() }
    return $null
}

# --- PATH preparation -------------------------------------------------------
$pythonRoot = Get-PythonRoot
if ($pythonRoot) { $env:Path = "$pythonRoot;$env:Path" }

# --- Pass 1: everything already on PATH -------------------------------------
$map = @{}
foreach ($t in $TOOLS) {
    $c = Get-Command $t -ErrorAction SilentlyContinue
    if ($c -and $c.Source) { $map[$t] = $c.Source }
}

# --- Pass 2: vswhere fallback, only if a tool is still missing --------------
$offPath = @{}
$needVs = (-not $map.ContainsKey('cl')) -or (-not $map.ContainsKey('ninja'))
$vsPath = $null
if ($needVs) {
    $vsPath = Get-VsPath
    if ($vsPath) {
        if (-not $map.ContainsKey('cl')) {
            $cl = Get-ChildItem "$vsPath\VC\Tools\MSVC" -Recurse -Filter cl.exe -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -match 'HostX64\\x64' } |
                Select-Object -First 1 -ExpandProperty FullName
            if ($cl) { $map['cl'] = $cl; $offPath['cl'] = $true }
        }
        if (-not $map.ContainsKey('ninja')) {
            $ninja = Get-ChildItem "$vsPath\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja" `
                -Filter ninja.exe -ErrorAction SilentlyContinue |
                Select-Object -First 1 -ExpandProperty FullName
            if ($ninja) { $map['ninja'] = $ninja; $offPath['ninja'] = $true }
        }
    }
}

# --- Version probe ----------------------------------------------------------
# Kept to a small set because spawning an interpreter costs ~50-100ms each on
# this CPU, and most tools do not expose a cheap reliable version flag.
function Get-ToolVersion {
    param([string]$Tool, [string]$Exe)
    try {
        switch ($Tool) {
            'python' { return (& $Exe --version 2>&1 | Select-Object -First 1) -replace '^Python\s+', '' }
            'pip'    { return (& $Exe --version 2>&1 | Select-Object -First 1) -replace '^pip\s+', '' -replace '\s+from.*$', '' }
            'git'    { return (& $Exe --version 2>&1 | Select-Object -First 1) -replace '^git version\s+', '' }
            'node'   { return (& $Exe --version 2>&1 | Select-Object -First 1) }
            'npm'    { return (& $Exe --version 2>&1 | Select-Object -First 1) }
            'go'     { return (& $Exe version 2>&1 | Select-Object -First 1) -replace '^go version\s+\S+\s+', '' }
            'java'   { return (& $Exe --version 2>&1 | Select-Object -First 1) }
            'cmake'  { return (& $Exe --version 2>&1 | Select-Object -First 1) }
            'cargo'  { return (& $Exe --version 2>&1 | Select-Object -First 1) -replace '^cargo\s+', '' }
            'uv'     { return (& $Exe --version 2>&1 | Select-Object -First 1) -replace '^uv\s+', '' }
            default  { return $null }
        }
    } catch { return $null }
}

# Only probe versions for tools that are actually present and cheap enough.
$VERSIONED = @('python', 'pip', 'git', 'node', 'npm', 'cmake', 'cargo', 'go', 'uv')
$versions = @{}
foreach ($t in $VERSIONED) {
    if ($map.ContainsKey($t)) {
        $v = Get-ToolVersion -Tool $t -Exe $map[$t]
        if ($v) { $versions[$t] = "$v".Trim() }
    }
}

# --- Emit -------------------------------------------------------------------
$out = [ordered]@{
    python_root      = $pythonRoot
    vs_path          = $vsPath
    tool_count       = $map.Count
    tool_total       = $TOOLS.Count
    tools            = [ordered]@{}
    versions         = [ordered]@{}
    not_on_path      = @($offPath.Keys)
    missing          = @($TOOLS | Where-Object { -not $map.ContainsKey($_) })
    machine_guid     = $null
    computer_name    = $env:COMPUTERNAME
    probed_at        = (Get-Date).ToString('o')
}

foreach ($k in ($map.Keys | Sort-Object)) { $out.tools[$k] = $map[$k] }
foreach ($k in ($versions.Keys | Sort-Object)) { $out.versions[$k] = $versions[$k] }

$guid = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography' -ErrorAction SilentlyContinue).MachineGuid
if ($guid) { $out.machine_guid = $guid }

$out | ConvertTo-Json -Depth 6 -Compress
