param(
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$InstallerScript = Join-Path $PSScriptRoot 'machine-env-cpp.nsi'
$ConfigScript = Join-Path $PSScriptRoot 'configure-mcp.ps1'
$InstructionsFile = Join-Path $PSScriptRoot 'machine-env-cpp.instructions.md'
$BuildDirectory = Join-Path $Root 'build\installer-build'
$StagedExe = Join-Path $BuildDirectory 'machine-env-cpp.exe'
$DefaultExe = Join-Path $Root 'build\machine-env-cpp.exe'
$OutputDirectory = Join-Path $Root 'build\installer'
$OutputFile = Join-Path $OutputDirectory 'machine-env-cpp-setup.exe'

if (-not $SkipBuild) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'build.ps1') $BuildDirectory
    if ($LASTEXITCODE -ne 0) {
        throw "Native build failed with exit code $LASTEXITCODE"
    }
}

# build.ps1 configures Release regardless of the output directory, so the
# default build output is the same artifact as the staged one. Falling back to
# it keeps -SkipBuild meaning "do not compile" instead of "you must have run a
# full installer build at least once".
$SourceExe = $StagedExe
if (-not (Test-Path -LiteralPath $SourceExe -PathType Leaf) -and
    (Test-Path -LiteralPath $DefaultExe -PathType Leaf)) {
    $SourceExe = $DefaultExe
    Write-Host "Reusing the build output at $SourceExe" -ForegroundColor Yellow
}
if (-not (Test-Path -LiteralPath $SourceExe -PathType Leaf)) {
    throw "No built server to package. Run scripts\build.ps1, or omit -SkipBuild to compile now. Looked for: $StagedExe and $DefaultExe"
}

$makensis = (Get-Command makensis -ErrorAction SilentlyContinue).Source
if (-not $makensis) {
    $candidate = Join-Path ${env:ProgramFiles(x86)} 'NSIS\makensis.exe'
    if (Test-Path -LiteralPath $candidate) {
        $makensis = $candidate
    }
}
if (-not $makensis) {
    throw 'NSIS makensis.exe was not found. Install NSIS to build the desktop installer.'
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
& $makensis '/V2' "/DSourceExe=$SourceExe" "/DConfigScript=$ConfigScript" `
    "/DInstructionsFile=$InstructionsFile" "/DOutputFile=$OutputFile" $InstallerScript
if ($LASTEXITCODE -ne 0) {
    throw "NSIS compilation failed with exit code $LASTEXITCODE"
}
if (-not (Test-Path -LiteralPath $OutputFile -PathType Leaf)) {
    throw "NSIS completed without producing the installer: $OutputFile"
}

Write-Host "`nInstaller built: $OutputFile" -ForegroundColor Green
