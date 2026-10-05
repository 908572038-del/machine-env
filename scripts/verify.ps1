param(
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot

function Write-Step([string]$Text) {
    Write-Host "`n== $Text" -ForegroundColor Cyan
}

function Assert-That([bool]$Condition, [string]$Text) {
    if (-not $Condition) {
        throw "verification failed: $Text"
    }
    Write-Host "   OK  $Text" -ForegroundColor Green
}

# Sends real bytes through the server, so no PowerShell re-encoding is involved.
function Invoke-Stdio([string[]]$Messages) {
    $wirePath = Join-Path $env:TEMP "machine-env-verify-$PID.jsonl"
    [System.IO.File]::WriteAllLines($wirePath, $Messages,
                                    (New-Object System.Text.UTF8Encoding $false))
    try {
        $start = New-Object System.Diagnostics.ProcessStartInfo
        $start.FileName = $env:ComSpec
        $start.Arguments = '/d /c type "' + $wirePath + '" | "' + $script:Server + '"'
        $start.UseShellExecute = $false
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.StandardOutputEncoding = New-Object System.Text.UTF8Encoding $false
        $start.StandardErrorEncoding = New-Object System.Text.UTF8Encoding $false
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $start
        if (-not $process.Start()) { throw 'could not start the MCP server' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(60000)) {
            $process.Kill()
            throw 'MCP server timed out during verification'
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $process.Dispose()
        if ($stderr) { Write-Host $stderr.Trim() -ForegroundColor DarkGray }
        return @(
            $stdout -split "`r?`n" | Where-Object { $_ } |
                ForEach-Object { $_ | ConvertFrom-Json -ErrorAction Stop }
        )
    } finally {
        Remove-Item -LiteralPath $wirePath -Force -ErrorAction SilentlyContinue
    }
}

if (-not $SkipBuild) {
    Write-Step 'Build and native self-test'
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'build.ps1')
    if ($LASTEXITCODE -ne 0) { throw "build failed with exit code $LASTEXITCODE" }
}

$sandbox = Join-Path $env:TEMP ("machine-env-verify-" + [guid]::NewGuid().ToString('N'))
$savedLocalAppData = $env:LOCALAPPDATA
$savedAppData = $env:APPDATA
$savedCopilotHome = $env:COPILOT_HOME

$env:LOCALAPPDATA = Join-Path $sandbox 'local'
$env:APPDATA = Join-Path $sandbox 'appdata'
$env:COPILOT_HOME = Join-Path $sandbox 'copilot'
New-Item -ItemType Directory -Path $env:LOCALAPPDATA, $env:APPDATA, $env:COPILOT_HOME -Force |
    Out-Null

$installDirectory = Join-Path $env:LOCALAPPDATA 'Programs\machine-env-cpp'
$script:Server = Join-Path $installDirectory 'machine-env-cpp.exe'
$configPath = Join-Path $env:COPILOT_HOME 'mcp-config.json'
$vscodeRule = Join-Path $env:APPDATA 'Code\User\prompts\machine-env-cpp.instructions.md'
$copilotRule = Join-Path $env:COPILOT_HOME 'instructions\machine-env-cpp.instructions.md'
$promptsDirectory = Join-Path $env:APPDATA 'Code\User\prompts'

try {
    Write-Step 'Install into a throwaway profile'
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'install.ps1') -SkipBuild
    if ($LASTEXITCODE -ne 0) { throw "install failed with exit code $LASTEXITCODE" }

    Write-Step 'Installed layout'
    Assert-That (Test-Path -LiteralPath $script:Server) 'server executable installed'
    Assert-That (Test-Path -LiteralPath $configPath) 'global MCP config written'
    Assert-That (Test-Path -LiteralPath $vscodeRule) 'scoped instruction installed'
    # A second copy would double the prompt cost for every request.
    Assert-That (-not (Test-Path -LiteralPath $copilotRule)) 'no duplicate instruction in the Copilot folder'
    $configured = (Get-Content -LiteralPath $configPath -Encoding UTF8 -Raw |
        ConvertFrom-Json).mcpServers.'machine-env-cpp'.command
    Assert-That ($configured -eq $script:Server) 'config points at the installed executable'
    $promptRules = @(Get-ChildItem -LiteralPath $promptsDirectory -Filter '*.instructions.md' -ErrorAction SilentlyContinue)
    Assert-That ($promptRules.Count -eq 1) 'exactly one instruction file in the prompts folder'

    Write-Step 'Protocol contract'
    $responses = Invoke-Stdio @(
        '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}',
        '{"jsonrpc":"2.0","id":2,"method":"tools/list"}',
        '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_tools","arguments":{"bogus":1}}}',
        '{"jsonrpc":"2.0","id":4,"method":"resources/list"}',
        '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"get_system","arguments":{"detail":true}}}',
        '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"get_apps","arguments":{"detail":true}}}'
    )
    $byId = @{}
    foreach ($response in $responses) { $byId[[string]$response.id] = $response }
    Assert-That ($byId.Count -eq 6) "answered all six requests (got $($byId.Count))"

    Assert-That ($byId['1'].result.serverInfo.name -eq 'machine-env-cpp') 'initialize reports the server identity'
    $expectedTools = @('get_system', 'get_tools', 'get_apps', 'get_network')
    $names = @($byId['2'].result.tools | ForEach-Object { $_.name })
    Assert-That (($names.Count -eq 4) -and
        (@($expectedTools | Where-Object { $_ -notin $names }).Count -eq 0)) "tools/list exposes exactly: $($expectedTools -join ', ')"
    Assert-That ($byId['3'].error.code -eq -32602) 'unknown argument is rejected with -32602'
    Assert-That ($byId['4'].error.code -eq -32601) 'resources/list is not offered without the capability'
    # Assertions stay ASCII-only so the script cannot break on code page changes.
    $system = $byId['5'].result.structuredContent
    Assert-That ((-not $byId['5'].result.isError) -and $system.os.caption -and $system.hardware.brand) 'get_system returns system facts'
    # Free physical memory does not answer whether a large allocation fits.
    Assert-That ($system.os.commit_limit_mb -gt 0) 'get_system reports a commit limit'
    # The registry is what a new shell inherits; the process copy can be stale,
    # and a refresh could never correct it.
    Assert-That ($system.paths.path_source -eq 'registry') 'PATH is read from the registry rather than the process environment'
    $apps = $byId['6'].result.structuredContent
    Assert-That ($apps.count -is [int] -or $apps.count -is [long]) 'get_apps reports an application count'
    Assert-That ($apps.apps -is [array]) 'get_apps returns an application array'

    Write-Step 'Tool lookup outside the probed catalog'
    # A requested name the catalog does not probe must be answered rather than
    # omitted: an empty answer is read as "not present".
    $lookup = (Invoke-Stdio @('{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_tools","arguments":{"name":"no-such-tool-xyz"}}}'))[0]
    Assert-That ($lookup.result.content[0].text.Contains('NO-SUCH-TOOL-XYZ = ')) 'a name outside the probed catalog is answered rather than omitted'
    # A filter that matches nothing must also say so instead of returning silence.
    $phrase = (Invoke-Stdio @('{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_tools","arguments":{"name":"no such phrase"}}}'))[0]
    Assert-That ($phrase.result.content[0].text.Contains('no such phrase')) 'a filter that matches nothing says so'

    Write-Step 'Cache integrity'
    # A cache entry is not trusted blindly: an entry changed by something else
    # must be discarded and re-probed, never served as fact.
    $cacheFile = Join-Path $env:LOCALAPPDATA 'machine-env\cache\system.json'
    Assert-That (Test-Path -LiteralPath $cacheFile) 'system probe wrote a cache entry'
    $readSystem = '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_system","arguments":{"detail":true}}}'
    $served = (Invoke-Stdio @($readSystem))[0].result.structuredContent
    Assert-That ($served._cache.hit -eq $true) 'an untouched cache entry is served from cache'
    $trueMemory = [string]$served.os.total_mem_mb
    $entryText = [System.IO.File]::ReadAllText($cacheFile)
    $needle = '"total_mem_mb":' + $trueMemory
    Assert-That ($entryText.Contains($needle)) 'the cache entry records the probed memory figure'
    [System.IO.File]::WriteAllText($cacheFile, $entryText.Replace($needle, '"total_mem_mb":1024'),
                                   (New-Object System.Text.UTF8Encoding $false))
    $rejected = (Invoke-Stdio @($readSystem))[0].result.structuredContent
    Assert-That ($rejected._cache.hit -eq $false) 'a tampered cache entry is rejected'
    Assert-That ($rejected._cache.reason -eq 'cache failed its checksum') 'the rejection names the checksum'
    Assert-That ([string]$rejected.os.total_mem_mb -eq $trueMemory) 'the tampered figure is not served'
    $healed = (Invoke-Stdio @($readSystem))[0].result.structuredContent
    Assert-That ($healed._cache.hit -eq $true) 'the cache heals itself on the next call'

    Write-Step 'Uninstall'
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $installDirectory 'uninstall-portable.ps1')
    if ($LASTEXITCODE -ne 0) { throw "uninstall failed with exit code $LASTEXITCODE" }
    $servers = (Get-Content -LiteralPath $configPath -Encoding UTF8 -Raw |
        ConvertFrom-Json).mcpServers
    Assert-That (($null -eq $servers) -or ($null -eq $servers.'machine-env-cpp')) 'config entry removed'
    Assert-That (-not (Test-Path -LiteralPath $vscodeRule)) 'scoped instruction removed'
    Assert-That (-not (Test-Path -LiteralPath $installDirectory)) 'install directory removed'

    Write-Host "`nVERIFY: PASS" -ForegroundColor Green
} finally {
    $env:LOCALAPPDATA = $savedLocalAppData
    $env:APPDATA = $savedAppData
    if ($null -eq $savedCopilotHome) {
        Remove-Item Env:COPILOT_HOME -ErrorAction SilentlyContinue
    } else {
        $env:COPILOT_HOME = $savedCopilotHome
    }
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}
