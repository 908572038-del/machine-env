param(
    # Client to register. Defaults to copilot; use -Client all for every client.
    [string]$Client = 'copilot',
    [switch]$ListClients
)

$ErrorActionPreference = 'Stop'

$sourceServer = Join-Path $PSScriptRoot 'machine-env-cpp.exe'
$configScript = Join-Path $PSScriptRoot 'configure-mcp.ps1'
$uninstallScript = Join-Path $PSScriptRoot 'uninstall-portable.ps1'
$registrySource = Join-Path $PSScriptRoot 'client-registry.ps1'
if (-not (Test-Path -LiteralPath $sourceServer -PathType Leaf)) {
    throw "machine-env-cpp.exe was not found beside this script: $sourceServer"
}
if (-not (Test-Path -LiteralPath $configScript -PathType Leaf)) {
    throw "configure-mcp.ps1 was not found beside this script: $configScript"
}
if (-not (Test-Path -LiteralPath $uninstallScript -PathType Leaf)) {
    throw "uninstall-portable.ps1 was not found beside this script: $uninstallScript"
}
if (-not (Test-Path -LiteralPath $registrySource -PathType Leaf)) {
    throw "client-registry.ps1 was not found beside this script: $registrySource"
}
. $registrySource

if ($ListClients) {
    Write-Host 'Supported MCP clients:'
    foreach ($name in Get-McpClientNames) {
        $spec = Get-McpClientSpec -Name $name
        Write-Host ("  {0,-16} {1}" -f $name, $spec.Display)
        Write-Host ("  {0,-16} -> {1}" -f '', $spec.ConfigPath)
    }
    return
}

$clients = if ($Client -eq 'all') { Get-McpClientNames } else { @($Client) }
foreach ($c in $clients) { [void](Get-McpClientSpec -Name $c) }

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
Copy-Item -LiteralPath $registrySource -Destination $installDirectory -Force

Write-Host "Registering machine-env-cpp for: $($clients -join ', ')" -ForegroundColor Cyan
foreach ($c in $clients) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $configScript `
        -Mode Install -ExePath $installedServer -Client $c
    if ($LASTEXITCODE -ne 0) {
        throw "MCP registration failed for client '$c' (exit code $LASTEXITCODE)"
    }
}

Write-Host "Installed: $installedServer" -ForegroundColor Green
Write-Host "Uninstall with: powershell -ExecutionPolicy Bypass -File '$installDirectory\uninstall-portable.ps1'"
Write-Host 'Restart the registered client(s) to start machine-env-cpp.'
