$ErrorActionPreference = 'Stop'

$installDirectory = $PSScriptRoot
$server = Join-Path $installDirectory 'machine-env-cpp.exe'
$configScript = Join-Path $installDirectory 'configure-mcp.ps1'
$instructions = Join-Path $installDirectory 'machine-env-cpp.instructions.md'

foreach ($path in @($server, $configScript, $instructions)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required MCP uninstall file is missing: $path"
    }
}

Write-Host 'Removing machine-env-cpp MCP registration and its scoped instructions' -ForegroundColor Cyan
& powershell -NoProfile -ExecutionPolicy Bypass -File $configScript `
    -Mode Uninstall -ExePath $server -InstructionsPath $instructions
if ($LASTEXITCODE -ne 0) {
    throw "MCP configuration cleanup failed with exit code $LASTEXITCODE"
}

foreach ($name in @(
    'machine-env-cpp.exe',
    'configure-mcp.ps1',
    'machine-env-cpp.instructions.md',
    'uninstall-portable.ps1'
)) {
    # The registration is already gone, so a locked file must not abort cleanup.
    Remove-Item -LiteralPath (Join-Path $installDirectory $name) -Force `
        -ErrorAction SilentlyContinue
}
Remove-Item -LiteralPath $installDirectory -Recurse -Force `
    -ErrorAction SilentlyContinue
if (Test-Path -LiteralPath $installDirectory) {
    Write-Host "Some files remained in $installDirectory (close VS Code and delete the folder manually)." -ForegroundColor Yellow
}

Write-Host 'machine-env-cpp has been uninstalled.' -ForegroundColor Green
