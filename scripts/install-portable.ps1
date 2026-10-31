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
# An MCP server is started by its client and stays running while that client is
# open, which is exactly when someone installs an upgrade. Windows will not let a
# running executable be overwritten, but it will let it be renamed, so the old
# copy is moved aside first and the new one takes its place. The old file cannot
# be deleted while it still runs; a leftover is harmless and is cleaned up by the
# next install, which is better than failing the upgrade and leaving the user
# with a server they cannot update without knowing to close the editor.
if (Test-Path -LiteralPath $installedServer) {
    $retired = "$installedServer.old-$PID"
    try {
        Move-Item -LiteralPath $installedServer -Destination $retired -Force
    } catch {
        throw "Could not replace the running server at $installedServer. Close the editor or client that started it, then run this script again."
    }
    try {
        Remove-Item -LiteralPath $retired -Force -ErrorAction Stop
    } catch {
        Write-Host "The previous server is still running; its file is removed on the next install: $retired" -ForegroundColor Yellow
    }
}
Get-ChildItem -LiteralPath $installDirectory -Filter 'machine-env-cpp.exe.old-*' -ErrorAction SilentlyContinue |
    ForEach-Object {
        try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop } catch { }
    }
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
