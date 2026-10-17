$ErrorActionPreference = 'Stop'

$installDirectory = $PSScriptRoot
$server = Join-Path $installDirectory 'machine-env-cpp.exe'
$configScript = Join-Path $installDirectory 'configure-mcp.ps1'
$registryPath = Join-Path $installDirectory 'client-registry.ps1'

foreach ($path in @($server, $configScript)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required MCP uninstall file is missing: $path"
    }
}

# Remove the entry from every client we know about. Older installs may predate
# the registry, so fall back to copilot rather than failing the whole uninstall.
$clients = @('copilot')
if (Test-Path -LiteralPath $registryPath) {
    . $registryPath
    $clients = Get-McpClientNames
}

Write-Host 'Removing the machine-env-cpp MCP registration' -ForegroundColor Cyan
foreach ($c in $clients) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $configScript `
        -Mode Uninstall -ExePath $server -Client $c
    if ($LASTEXITCODE -ne 0) {
        throw "MCP configuration cleanup failed for client '$c' (exit code $LASTEXITCODE)"
    }
}

foreach ($name in @(
    'machine-env-cpp.exe',
    'configure-mcp.ps1',
    'uninstall-portable.ps1',
    'client-registry.ps1'
)) {
    # The registration is already gone, so a locked file must not abort cleanup.
    Remove-Item -LiteralPath (Join-Path $installDirectory $name) -Force `
        -ErrorAction SilentlyContinue
}
Remove-Item -LiteralPath $installDirectory -Recurse -Force `
    -ErrorAction SilentlyContinue
if (Test-Path -LiteralPath $installDirectory) {
    Write-Host "Some files remained in $installDirectory (close any client using the server and delete the folder manually)." -ForegroundColor Yellow
}

Write-Host 'machine-env-cpp has been uninstalled.' -ForegroundColor Green
