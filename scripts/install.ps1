param(
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root
$serverName = 'machine-env-cpp'
$previousServerName = 'machine-env'

function Write-Step([string]$Text) {
    Write-Host "`n== $Text" -ForegroundColor Cyan
}

function Write-Ok([string]$Text) {
    Write-Host "   OK  $Text" -ForegroundColor Green
}

if (-not $SkipBuild) {
    Write-Step 'Building native C++ MCP server'
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'build.ps1')
    if ($LASTEXITCODE -ne 0) {
        throw "Native build failed with exit code $LASTEXITCODE"
    }
}

$builtServer = Join-Path $Root 'build\machine-env-cpp.exe'
$configScriptSource = Join-Path $PSScriptRoot 'configure-mcp.ps1'
$uninstallScriptSource = Join-Path $PSScriptRoot 'uninstall-portable.ps1'
if (-not (Test-Path -LiteralPath $builtServer)) {
    throw "Native MCP server was not produced: $builtServer"
}
if (-not (Test-Path -LiteralPath $configScriptSource -PathType Leaf) -or
    -not (Test-Path -LiteralPath $uninstallScriptSource -PathType Leaf)) {
    throw 'MCP install or uninstall support scripts were not found.'
}
if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    throw 'LOCALAPPDATA is not set; cannot determine the per-user install directory.'
}
$installDirectory = Join-Path $env:LOCALAPPDATA 'Programs\machine-env-cpp'
$server = Join-Path $installDirectory 'machine-env-cpp.exe'
New-Item -ItemType Directory -Path $installDirectory -Force | Out-Null
Copy-Item -LiteralPath $builtServer -Destination $server -Force
Copy-Item -LiteralPath $configScriptSource -Destination $installDirectory -Force
Copy-Item -LiteralPath $uninstallScriptSource -Destination $installDirectory -Force

Write-Step 'Updating VS Code MCP configuration'
$copilotHome = if ([string]::IsNullOrWhiteSpace($env:COPILOT_HOME)) {
    Join-Path $env:USERPROFILE '.copilot'
} else {
    $env:COPILOT_HOME
}
$configPath = Join-Path $copilotHome 'mcp-config.json'
$configDir = Split-Path -Parent $configPath
if (-not (Test-Path -LiteralPath $configDir)) {
    New-Item -ItemType Directory -Force -Path $configDir | Out-Null
}

$existing = $null
if (Test-Path -LiteralPath $configPath) {
    try {
        $existing = Get-Content -LiteralPath $configPath -Encoding UTF8 -Raw |
            ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Refusing to overwrite invalid MCP config '$configPath': $($_.Exception.Message)"
    }
    if ($null -eq $existing -or $existing -is [array]) {
        throw "Refusing to overwrite '$configPath': expected a JSON object."
    }
    if ($existing.PSObject.Properties.Name -contains 'mcpServers' -and
        $null -ne $existing.mcpServers -and
        $existing.mcpServers -isnot [System.Management.Automation.PSCustomObject]) {
        throw "Refusing to overwrite '$configPath': 'mcpServers' must be a JSON object."
    }
    if (-not (Test-Path -LiteralPath "$configPath.bak")) {
        Copy-Item -LiteralPath $configPath -Destination "$configPath.bak" -Force
    }
}

$servers = [ordered]@{}
if ($existing -and $existing.mcpServers) {
    foreach ($property in $existing.mcpServers.PSObject.Properties) {
        if ($property.Name -eq $previousServerName) {
            # Drop the legacy entry only when it points into this product's
            # install directory; a user's own server of that name is kept.
            $legacy = [string]$property.Value.command
            $belongs = $false
            if (-not [string]::IsNullOrWhiteSpace($legacy)) {
                try {
                    $resolved = [System.IO.Path]::GetFullPath($legacy)
                    $belongs = $resolved.StartsWith(
                        $installDirectory + '\',
                        [System.StringComparison]::OrdinalIgnoreCase)
                } catch {
                    $belongs = $false
                }
            }
            if ($belongs) { continue }
        }
        $servers[$property.Name] = $property.Value
    }
}
$servers[$serverName] = [ordered]@{
    type = 'stdio'
    command = $server
    env = [ordered]@{}
}

$merged = [ordered]@{}
if ($existing) {
    foreach ($property in $existing.PSObject.Properties) {
        if ($property.Name -ne 'mcpServers') {
            $merged[$property.Name] = $property.Value
        }
    }
}
$merged['mcpServers'] = $servers
$json = $merged | ConvertTo-Json -Depth 20
$encoding = New-Object System.Text.UTF8Encoding $false
$temporaryConfig = "$configPath.$PID.tmp"
try {
    [System.IO.File]::WriteAllText($temporaryConfig, $json, $encoding)
    Move-Item -LiteralPath $temporaryConfig -Destination $configPath -Force
} finally {
    if (Test-Path -LiteralPath $temporaryConfig) {
        Remove-Item -LiteralPath $temporaryConfig -Force
    }
}
Write-Ok "wrote $configPath"

if (Test-Path -LiteralPath "$configPath.bak") {
    Write-Host "        prior config backed up to $configPath.bak"
}

Write-Step 'Verifying actual MCP stdio connection'
$wirePath = Join-Path $env:TEMP "machine-env-install-$PID.jsonl"
$requests = @(
    ([ordered]@{
        jsonrpc = '2.0'
        id = 1
        method = 'initialize'
        params = @{
            protocolVersion = '2025-11-25'
            capabilities = @{}
            clientInfo = @{ name = 'machine-env-installer'; version = '1' }
        }
    } | ConvertTo-Json -Depth 20 -Compress),
    '{"jsonrpc":"2.0","method":"notifications/initialized"}',
    ([ordered]@{ jsonrpc = '2.0'; id = 2; method = 'tools/list'; params = @{} } |
        ConvertTo-Json -Depth 20 -Compress),
    ([ordered]@{
        jsonrpc = '2.0'
        id = 3
        method = 'tools/call'
        params = @{ name = 'get_system'; arguments = @{ detail = $true } }
    } | ConvertTo-Json -Depth 20 -Compress),
    ([ordered]@{
        jsonrpc = '2.0'
        id = 4
        method = 'tools/call'
        params = @{ name = 'get_tools'; arguments = @{ detail = $true } }
    } | ConvertTo-Json -Depth 20 -Compress)
)
[System.IO.File]::WriteAllLines(
    $wirePath, $requests, [System.Text.Encoding]::ASCII
)

$start = New-Object System.Diagnostics.ProcessStartInfo
$start.FileName = $env:ComSpec
$start.Arguments = '/d /c type "' + $wirePath + '" | "' + $server + '"'
$start.WorkingDirectory = $Root
$start.UseShellExecute = $false
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$utf8 = New-Object System.Text.UTF8Encoding $false
$start.StandardOutputEncoding = $utf8
$start.StandardErrorEncoding = $utf8
$process = New-Object System.Diagnostics.Process
$process.StartInfo = $start
try {
    if (-not $process.Start()) {
        throw 'Could not start the native MCP server.'
    }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(30000)) {
        $process.Kill()
        throw 'MCP stdio verification timed out.'
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $responses = @(
        $stdout -split "`r?`n" |
            Where-Object { $_ } |
            ForEach-Object { $_ | ConvertFrom-Json -ErrorAction Stop }
    )
    if ($responses.Count -ne 4) {
        throw "Expected 4 JSON-RPC responses; received $($responses.Count). stderr: $stderr"
    }
    $byId = @{}
    foreach ($response in $responses) {
        if ($response.error) {
            throw "MCP request $($response.id) failed: $($response.error.message)"
        }
        $byId[[string]$response.id] = $response
    }
    $initialize = $byId['1']
    if ($initialize.result.serverInfo.name -ne $serverName) {
        throw "Unexpected MCP server identity: $($initialize | ConvertTo-Json -Compress -Depth 6)"
    }
    $listing = $byId['2']
    $names = @($listing.result.tools | ForEach-Object { $_.name })
    $expected = @(
        'get_system',
        'get_tools',
        'get_apps',
        'get_network'
    )
    if ($listing.error -or (@($expected | Where-Object { $_ -notin $names }).Count -gt 0)) {
        throw "MCP tools/list is incomplete: $($names -join ', ')"
    }
    if ($names.Count -ne $expected.Count) {
        throw "Expected exactly $($expected.Count) tools; received $($names.Count)."
    }
    $systemResult = $byId['3']
    if ($systemResult.result.isError) {
        throw "get_system reported an error: $($systemResult | ConvertTo-Json -Compress -Depth 6)"
    }
    $data = $systemResult.result.structuredContent
    if (-not $data.os -or -not $data.hardware -or -not $data.hardware.brand) {
        throw "MCP system probe failed: $($systemResult | ConvertTo-Json -Compress -Depth 6)"
    }
    $toolsResult = $byId['4'].result.structuredContent
    if (-not $toolsResult.tools) {
        throw 'MCP toolchain probe returned an invalid result.'
    }
    Write-Ok "handshake: $($initialize.result.serverInfo.name) v$($initialize.result.serverInfo.version)"
    Write-Ok "tools: $($names -join ', ')"
    Write-Ok "system: $($data.os.caption), $($data.hardware.brand)"
    Write-Ok "tools probe: $($toolsResult.tool_count) detected"
} finally {
    $process.Dispose()
    Remove-Item -LiteralPath $wirePath -Force -ErrorAction SilentlyContinue
}

Write-Host "`nINSTALL COMPLETE - machine-env-cpp MCP is configured." -ForegroundColor Green
