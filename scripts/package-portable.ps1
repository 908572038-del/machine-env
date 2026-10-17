param(
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$BuildScript = Join-Path $PSScriptRoot 'build.ps1'
$SourceServer = Join-Path $Root 'build\machine-env-cpp.exe'
$OutputDirectory = Join-Path $Root 'build\release'
$PackagePath = Join-Path $OutputDirectory 'machine-env-cpp-windows-x64.zip'
$StageDirectory = Join-Path $OutputDirectory ".stage-$PID"

if (-not $SkipBuild) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $BuildScript
    if ($LASTEXITCODE -ne 0) {
        throw "Native build failed with exit code $LASTEXITCODE"
    }
}
if (-not (Test-Path -LiteralPath $SourceServer -PathType Leaf)) {
    throw "Native executable not found: $SourceServer"
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
# Cleanup must never decide the outcome of the package: a leftover directory is
# uglier than a missing zip, but it is not a build failure, so the removal is
# wrapped instead of being allowed to throw out of the finally block and mask a
# package that was actually produced.
$removeTree = {
    param([string]$Path)
    if (-not [System.IO.Directory]::Exists($Path)) { return }
    try { [System.IO.Directory]::Delete($Path, $true) } catch {
        Write-Warning "Could not remove the staging directory, it can be deleted later: $Path"
    }
}
& $removeTree $StageDirectory
New-Item -ItemType Directory -Path $StageDirectory -Force | Out-Null
# Compress into a temporary archive and swap it in only once it is complete. A
# compression that fails partway must not leave an older archive sitting at the
# output path looking like this build's package.
$PartialPath = "$PackagePath.partial.zip"
try {
    Copy-Item -LiteralPath $SourceServer -Destination (Join-Path $StageDirectory 'machine-env-cpp.exe')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'install-portable.ps1') -Destination $StageDirectory
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'uninstall-portable.ps1') -Destination $StageDirectory
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'configure-mcp.ps1') -Destination $StageDirectory
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'client-registry.ps1') -Destination $StageDirectory
    if ([System.IO.File]::Exists($PartialPath)) { [System.IO.File]::Delete($PartialPath) }
    Compress-Archive -Path (Join-Path $StageDirectory '*') -DestinationPath $PartialPath -Force
    if ([System.IO.File]::Exists($PackagePath)) { [System.IO.File]::Delete($PackagePath) }
    Move-Item -LiteralPath $PartialPath -Destination $PackagePath -Force
} finally {
    if ([System.IO.File]::Exists($PartialPath) -and
        -not [System.IO.File]::Exists($PackagePath)) {
        Write-Warning "Packaging did not complete; the partial archive is at $PartialPath"
    }
    & $removeTree $StageDirectory
}

Write-Host "Portable package created: $PackagePath" -ForegroundColor Green
