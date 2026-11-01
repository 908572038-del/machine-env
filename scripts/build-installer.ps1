param(
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$InstallerScript = Join-Path $PSScriptRoot 'machine-env-cpp.nsi'
$ConfigScript = Join-Path $PSScriptRoot 'configure-mcp.ps1'
$RegistryScript = Join-Path $PSScriptRoot 'client-registry.ps1'
foreach ($required in @($InstallerScript, $ConfigScript, $RegistryScript)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Missing installer input: $required"
    }
}
$BuildDirectory = Join-Path $Root 'build\installer-build'
$StagedExe = Join-Path $BuildDirectory 'machine-env-cpp.exe'
$DefaultExe = Join-Path $Root 'build\machine-env-cpp.exe'
# CMake's Visual Studio generator writes into a per-configuration directory,
# which is what a CI job gets from `cmake -A x64`. Accepting it here means the
# installer can be built from the same build tree the ZIP came from.
$ConfigExe = Join-Path $Root 'build\Release\machine-env-cpp.exe'
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
# The staged build is preferred, then the two layouts a plain build can leave.
$SourceExe = $null
foreach ($candidate in @($StagedExe, $DefaultExe, $ConfigExe)) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        $SourceExe = $candidate
        break
    }
}
if (-not $SourceExe) {
    throw ("No built server to package. Run scripts\build.ps1, or omit -SkipBuild to compile now. Looked for:`n  " +
        (@($StagedExe, $DefaultExe, $ConfigExe) -join "`n  "))
}
if ($SourceExe -ne $StagedExe) {
    Write-Host "Reusing the build output at $SourceExe" -ForegroundColor Yellow
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
# The version is read from CMake rather than repeated here, so the installer's
# uninstall entry always names the server it actually contains. Reading it from
# the CMakeLists keeps this script working without configuring the project first.
$CMakeLists = Join-Path $Root 'CMakeLists.txt'
$AppVersion = '0.0.0'
if (Test-Path -LiteralPath $CMakeLists) {
    $match = Select-String -LiteralPath $CMakeLists -Pattern 'project\s*\([^)]*VERSION\s+([0-9]+\.[0-9]+\.[0-9]+)' |
        Select-Object -First 1
    if ($match) {
        $AppVersion = $match.Matches[0].Groups[1].Value
    }
}
if ($AppVersion -eq '0.0.0') {
    throw "Could not read the project version from $CMakeLists"
}
Write-Host "Packaging machine-env-cpp $AppVersion" -ForegroundColor Cyan
& $makensis '/V2' "/DSourceExe=$SourceExe" "/DConfigScript=$ConfigScript" `
    "/DRegistryScript=$RegistryScript" "/DOutputFile=$OutputFile" `
    "/DAppVersion=$AppVersion" $InstallerScript
if ($LASTEXITCODE -ne 0) {
    throw "NSIS compilation failed with exit code $LASTEXITCODE"
}
if (-not (Test-Path -LiteralPath $OutputFile -PathType Leaf)) {
    throw "NSIS completed without producing the installer: $OutputFile"
}

Write-Host "`nInstaller built: $OutputFile" -ForegroundColor Green
