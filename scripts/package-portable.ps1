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
if (Test-Path -LiteralPath $StageDirectory) {
    Remove-Item -LiteralPath $StageDirectory -Recurse -Force
}
New-Item -ItemType Directory -Path $StageDirectory -Force | Out-Null
try {
    Copy-Item -LiteralPath $SourceServer -Destination (Join-Path $StageDirectory 'machine-env-cpp.exe')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'install-portable.ps1') -Destination $StageDirectory
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'uninstall-portable.ps1') -Destination $StageDirectory
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'configure-mcp.ps1') -Destination $StageDirectory
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'machine-env-cpp.instructions.md') -Destination $StageDirectory
    Compress-Archive -Path (Join-Path $StageDirectory '*') -DestinationPath $PackagePath -Force
} finally {
    Remove-Item -LiteralPath $StageDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Portable package created: $PackagePath" -ForegroundColor Green
