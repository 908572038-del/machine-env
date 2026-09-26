# Build probe_hw.exe with MSVC.
#
# cl is not on PATH on this machine; vcvars64.bat must be sourced in the SAME
# cmd process as the compile, otherwise PATH/LIB/INCLUDE are lost and the
# compiler fails to find its own headers.

$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$src = Join-Path $here 'probe_hw.cpp'
$out = Join-Path $here 'build\probe_hw.exe'

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) {
    Write-Error "vswhere.exe not found at $vswhere. Install Visual Studio Build Tools."
    exit 1
}

$vs = & $vswhere -latest -property installationPath
if (-not $vs) {
    Write-Error "No Visual Studio installation found by vswhere."
    exit 1
}

$vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat'
if (-not (Test-Path $vcvars)) {
    Write-Error "vcvars64.bat not found at $vcvars"
    exit 1
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $out) | Out-Null

# /MT keeps the CRT static so the exe runs without redistributable concerns.
# /Fo pins the object file next to the binary: without it cl.exe writes the .obj
# into the *caller's* working directory, which scattered build artefacts into the
# repository root when install.ps1 invoked this script from there.
$obj = Join-Path (Split-Path -Parent $out) 'probe_hw.obj'
$cmd = 'call "' + $vcvars + '" >nul 2>&1 && cl /nologo /O2 /MT /EHsc /W4 /std:c++17 "' +
       $src + '" /Fo:"' + $obj + '" /Fe:"' + $out + '"'

& $env:ComSpec /c $cmd
if ($LASTEXITCODE -ne 0) {
    Write-Error "Compilation failed with exit code $LASTEXITCODE"
    exit $LASTEXITCODE
}

# Sweep strays from earlier builds that predate the /Fo pinning above.
foreach ($dir in @($here, (Split-Path -Parent $here), (Get-Location).Path)) {
    Get-ChildItem $dir -Filter '*.obj' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -ne $obj } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

if (Test-Path $out) {
    Write-Host "Built: $out"
    & $out
} else {
    Write-Error "Build reported success but $out is missing."
    exit 1
}
