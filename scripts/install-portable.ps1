$ErrorActionPreference = 'Stop'

$sourceServer = Join-Path $PSScriptRoot 'machine-env-cpp.exe'
$configScript = Join-Path $PSScriptRoot 'configure-mcp.ps1'
$uninstallScript = Join-Path $PSScriptRoot 'uninstall-portable.ps1'
if (-not (Test-Path -LiteralPath $sourceServer -PathType Leaf)) {
    throw "machine-env-cpp.exe was not found beside this script: $sourceServer"
}
if (-not (Test-Path -LiteralPath $configScript -PathType Leaf)) {
    throw "configure-mcp.ps1 was not found beside this script: $configScript"
}
if (-not (Test-Path -LiteralPath $uninstallScript -PathType Leaf)) {
    throw "uninstall-portable.ps1 was not found beside this script: $uninstallScript"
}
if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    throw 'LOCALAPPDATA is not set; cannot determine the per-user install directory.'
}

Write-Host 'Checking the downloaded server' -ForegroundColor Cyan
& $sourceServer --selftest
if ($LASTEXITCODE -ne 0) {
    throw "MCP self-test failed with exit code $LASTEXITCODE"
}

$installDirectory = Join-Path $env:LOCALAPPDATA 'Programs\machine-env-cpp'
$installedServer = Join-Path $installDirectory 'machine-env-cpp.exe'
New-Item -ItemType Directory -Path $installDirectory -Force | Out-Null
Copy-Item -LiteralPath $sourceServer -Destination $installedServer -Force
Copy-Item -LiteralPath $configScript -Destination $installDirectory -Force
Copy-Item -LiteralPath $uninstallScript -Destination $installDirectory -Force

$copilotHome = if ([string]::IsNullOrWhiteSpace($env:COPILOT_HOME)) {
    Join-Path $env:USERPROFILE '.copilot'
} else {
    $env:COPILOT_HOME
}
$configPath = Join-Path $copilotHome 'mcp-config.json'
Write-Host 'Registering the global VS Code Copilot MCP server' -ForegroundColor Cyan
& powershell -NoProfile -ExecutionPolicy Bypass -File $configScript `
    -Mode Install -ExePath $installedServer -ConfigPath $configPath
if ($LASTEXITCODE -ne 0) {
    throw "MCP registration failed with exit code $LASTEXITCODE"
}

Write-Host "Installed: $installedServer" -ForegroundColor Green
Write-Host "Uninstall with: powershell -ExecutionPolicy Bypass -File '$installDirectory\uninstall-portable.ps1'"
Write-Host 'Reload VS Code to start machine-env-cpp.'
