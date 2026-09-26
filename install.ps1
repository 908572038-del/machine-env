$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Root

function Write-Step([string]$Text) {
    Write-Host "`n== $Text" -ForegroundColor Cyan
}

function Write-Ok([string]$Text) {
    Write-Host "   OK  $Text" -ForegroundColor Green
}

Write-Step 'Building native C++ MCP server'
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'build.ps1')
if ($LASTEXITCODE -ne 0) {
    throw "Native build failed with exit code $LASTEXITCODE"
}

$server = Join-Path $Root 'build\machine-env.exe'
if (-not (Test-Path -LiteralPath $server)) {
    throw "Native MCP server was not produced: $server"
}

Write-Step 'Updating VS Code MCP configuration'
$configPath = Join-Path $env:USERPROFILE '.copilot\mcp-config.json'
$configDir = Split-Path -Parent $configPath
if (-not (Test-Path -LiteralPath $configDir)) {
    New-Item -ItemType Directory -Force -Path $configDir | Out-Null
}

$existing = $null
if (Test-Path -LiteralPath $configPath) {
    try {
        $existing = Get-Content -LiteralPath $configPath -Raw |
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
    Copy-Item -LiteralPath $configPath -Destination "$configPath.bak" -Force
}

$servers = [ordered]@{}
if ($existing -and $existing.mcpServers) {
    foreach ($property in $existing.mcpServers.PSObject.Properties) {
        $servers[$property.Name] = $property.Value
    }
}
$servers['machine-env'] = [ordered]@{
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
[System.IO.File]::WriteAllText($configPath, $json, $encoding)
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
        params = @{ name = 'get_hardware'; arguments = @{} }
    } | ConvertTo-Json -Depth 20 -Compress),
    ([ordered]@{
        jsonrpc = '2.0'
        id = 4
        method = 'tools/call'
        params = @{
            name = 'get_environment'
            arguments = @{ include_network = $false }
        }
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
    if ($initialize.result.serverInfo.name -ne 'machine-env') {
        throw "Unexpected MCP server identity: $($initialize | ConvertTo-Json -Compress -Depth 6)"
    }
    $listing = $byId['2']
    $names = @($listing.result.tools | ForEach-Object { $_.name })
    $expected = @(
        'get_hardware',
        'get_toolchain',
        'get_environment',
        'refresh_env',
        'get_cache_status'
    )
    if ($listing.error -or (@($expected | Where-Object { $_ -notin $names }).Count -gt 0)) {
        throw "MCP tools/list is incomplete: $($names -join ', ')"
    }
    $hardware = $byId['3']
    $data = $hardware.result.structuredContent
    if (-not $data.brand -or -not $data.isa) {
        throw "MCP hardware probe failed: $($hardware | ConvertTo-Json -Compress -Depth 6)"
    }
    $environment = $byId['4'].result.structuredContent
    if ($environment.network -or -not $environment.os -or -not $environment.paths) {
        throw 'Local-only environment probe returned an invalid result.'
    }
    Write-Ok "handshake: $($initialize.result.serverInfo.name) v$($initialize.result.serverInfo.version)"
    Write-Ok "tools: $($names -join ', ')"
    Write-Ok "hardware: $($data.brand), usable vector width $($data.vector_width_bits)"
    Write-Ok 'environment: local-only probe works without network requests'
} finally {
    $process.Dispose()
    Remove-Item -LiteralPath $wirePath -Force -ErrorAction SilentlyContinue
}

Write-Host "`nINSTALL COMPLETE — native C++ MCP is configured." -ForegroundColor Green
