param(
    [switch]$SkipBuild,

    # Client to register. Defaults to copilot for backward compatibility; use
    # -Client all to register every client in the registry.
    [string]$Client = 'copilot',

    [switch]$ListClients
)

$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root
$serverName = 'machine-env-cpp'

function Write-Step([string]$Text) {
    Write-Host "`n== $Text" -ForegroundColor Cyan
}

function Write-Ok([string]$Text) {
    Write-Host "   OK  $Text" -ForegroundColor Green
}

$registrySource = Join-Path $PSScriptRoot 'client-registry.ps1'
if (-not (Test-Path -LiteralPath $registrySource -PathType Leaf)) {
    throw "client-registry.ps1 was not found: $registrySource"
}
. $registrySource

if ($ListClients) {
    Write-Host 'Supported MCP clients:'
    foreach ($name in Get-McpClientNames) {
        $spec = Get-McpClientSpec -Name $name
        Write-Host ("  {0,-16} {1}" -f $name, $spec.Display)
        Write-Host ("  {0,-16} -> {1}" -f '', $spec.ConfigPath)
    }
    Write-Host "`nRun with -Client <name>, or -Client all to register every client."
    return
}

$clients = if ($Client -eq 'all') { Get-McpClientNames } else { @($Client) }
foreach ($c in $clients) {
    # Validate the name now so a typo fails before anything is written.
    [void](Get-McpClientSpec -Name $c)
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
# An editor that has already started the server holds the executable open, and
# the raw failure for that is a bare IOException on Copy-Item, which says
# nothing about what to close. Upgrading under a running client is the normal
# case, not an exotic one, so it is worth naming.
try {
    Copy-Item -LiteralPath $builtServer -Destination $server -Force
} catch [System.IO.IOException] {
    $holders = @(Get-Process -Name 'machine-env-cpp' -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty Id)
    $who = if ($holders.Count -gt 0) {
        "The server is running as process $($holders -join ', ')"
    } else {
        'The installed executable is in use'
    }
    throw "$who, so the installed copy at $server cannot be replaced. Close the editor or client that runs it (or stop that process) and run this again."
}
Copy-Item -LiteralPath $configScriptSource -Destination $installDirectory -Force
Copy-Item -LiteralPath $uninstallScriptSource -Destination $installDirectory -Force
Copy-Item -LiteralPath $registrySource -Destination $installDirectory -Force

Write-Step "Registering machine-env-cpp for: $($clients -join ', ')"
foreach ($c in $clients) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $configScriptSource `
        -Mode Install -ExePath $server -Client $c
    if ($LASTEXITCODE -ne 0) {
        throw "MCP registration failed for client '$c' (exit code $LASTEXITCODE)"
    }
    Write-Ok "registered: $c"
}

Write-Step 'Verifying actual MCP stdio connection'
# stdin stays open for the whole check, and every answer has to arrive while it
# is still open. Piping a file into the server proves that it answers at all,
# but only once the pipe ends -- a server that never answers a connected client
# passes that test and then fails inside the editor, which is how a build that
# could not complete a handshake came to be installed and reported as verified.
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

$start = New-Object System.Diagnostics.ProcessStartInfo
$start.FileName = $server
$start.WorkingDirectory = $Root
$start.UseShellExecute = $false
$start.RedirectStandardInput = $true
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
    # Drained in the background: a full stderr pipe would block the server.
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $responses = New-Object System.Collections.Generic.List[object]
    foreach ($request in $requests) {
        $process.StandardInput.WriteLine($request)
        $process.StandardInput.Flush()
        # A notification has no id and is not answered, so it is not waited for.
        if ($request -notmatch '"id"\s*:') { continue }
        $lineTask = $process.StandardOutput.ReadLineAsync()
        if (-not $lineTask.Wait(30000)) {
            throw 'MCP stdio verification timed out: a request was written but not answered while stdin was still open.'
        }
        $responses.Add(($lineTask.Result | ConvertFrom-Json -ErrorAction Stop))
    }
    # Closing stdin is the shutdown signal; a session that ends cleanly lets the
    # process end cleanly too.
    $process.StandardInput.Close()
    if (-not $process.WaitForExit(30000)) {
        $process.Kill()
        throw 'MCP stdio verification timed out on shutdown.'
    }
    $stderr = $stderrTask.GetAwaiter().GetResult()
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
}

Write-Host "`nINSTALL COMPLETE - machine-env-cpp MCP is configured for: $($clients -join ', ')." -ForegroundColor Green
