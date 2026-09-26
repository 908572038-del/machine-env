param(
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$InstallerScript = Join-Path $Root 'installer\machine-env-cpp.nsi'
$ConfigScript = Join-Path $Root 'installer\configure-mcp.ps1'
$BuildDirectory = Join-Path $Root 'build\installer-build'
$SourceExe = Join-Path $BuildDirectory 'machine-env-cpp.exe'
$OutputDirectory = Join-Path $Root 'build\installer'
$OutputFile = Join-Path $OutputDirectory 'machine-env-cpp-setup.exe'

if (-not $SkipBuild) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'build.ps1') $BuildDirectory
    if ($LASTEXITCODE -ne 0) {
        throw "Native build failed with exit code $LASTEXITCODE"
    }
}
if (-not (Test-Path -LiteralPath $SourceExe -PathType Leaf)) {
    throw "Native executable not found: $SourceExe"
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
    "/DOutputFile=$OutputFile" $InstallerScript
if ($LASTEXITCODE -ne 0) {
    throw "NSIS compilation failed with exit code $LASTEXITCODE"
}
if (-not (Test-Path -LiteralPath $OutputFile -PathType Leaf)) {
    throw "NSIS completed without producing the installer: $OutputFile"
}

Write-Host "`nInstaller built: $OutputFile" -ForegroundColor Green
