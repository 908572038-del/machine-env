param(
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$script:assertionCount = 0

function Write-Step([string]$Text) {
    Write-Host "`n== $Text" -ForegroundColor Cyan
}

function Assert-That([bool]$Condition, [string]$Text) {
    $script:assertionCount++
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

# Drives the server the way a client does: stdin stays open for the whole
# session and every answer has to arrive while it is still open. Feeding a file
# and closing the pipe answers "does the server ever respond", not "does it
# respond now" -- a read that only returns when the pipe ends looks identical
# under the first question and times out under the second.
function Invoke-LiveSession([string[]]$Messages, [int]$WaitMs = 20000,
                            [int]$SplitFirstAt = 0, [switch]$ShowDiagnostics) {
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $script:Server
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = New-Object System.Text.UTF8Encoding $false
    $start.StandardErrorEncoding = New-Object System.Text.UTF8Encoding $false
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $start
    if (-not $process.Start()) { throw 'could not start the MCP server' }
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $answers = New-Object System.Collections.Generic.List[object]
    $first = $true
    try {
        foreach ($message in $Messages) {
            if ($first -and $SplitFirstAt -gt 0 -and $SplitFirstAt -lt $message.Length) {
                # The pipe sits idle between the two halves: a read that assumes
                # a message arrives in one piece has to answer across the gap.
                $process.StandardInput.Write($message.Substring(0, $SplitFirstAt))
                $process.StandardInput.Flush()
                Start-Sleep -Milliseconds 150
                $process.StandardInput.WriteLine($message.Substring($SplitFirstAt))
            } else {
                $process.StandardInput.WriteLine($message)
            }
            $process.StandardInput.Flush()
            $lineTask = $process.StandardOutput.ReadLineAsync()
            if (-not $lineTask.Wait($WaitMs)) {
                throw "the server stayed silent for $WaitMs ms while stdin was still open"
            }
            $answers.Add(($lineTask.Result | ConvertFrom-Json -ErrorAction Stop))
            $first = $false
        }
    } finally {
        # Closing stdin is the shutdown signal, so this also asserts that a
        # session which ends cleanly lets the process end cleanly.
        try { $process.StandardInput.Close() } catch { }
        if (-not $process.WaitForExit(15000)) {
            $process.Kill()
            $process.WaitForExit(5000)
        }
        $process.Dispose()
    }
    if ($ShowDiagnostics) {
        # The process has exited by now, so the stderr read completes. The lines
        # are handed back through a script-scoped variable rather than mixed into
        # the answers: they are not responses and must never be counted as one.
        $null = $stderrTask.Wait(5000)
        if ($stderrTask.IsCompleted) {
            $script:liveDiagnostics = @($stderrTask.Result -split "`r?`n" |
                Where-Object { $_ -match 'diag:' })
        }
    }
    return $answers.ToArray()
}

# The handle count of a session that is still connected is the only place the
# worker pool is visible from outside: a std::thread holds its OS handle until it
# is joined, so a server that keeps every worker until end of input grows by
# about one handle per request. Sampling it in the middle of the session is what
# makes the difference visible -- after stdin closes the process is on its way
# out, and the growth is gone.
function Measure-LiveSessionHandles([string]$Handshake, [int]$Count) {
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $script:Server
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = New-Object System.Text.UTF8Encoding $false
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $start
    if (-not $process.Start()) { throw 'could not start the MCP server' }
    $null = $process.StandardError.ReadToEndAsync()
    $answered = 0
    $baseline = 0
    $final = 0
    try {
        $process.StandardInput.WriteLine($Handshake)
        $process.StandardInput.Flush()
        $null = $process.StandardOutput.ReadLine()
        $process.Refresh()
        $baseline = $process.HandleCount
        for ($index = 0; $index -lt $Count; ++$index) {
            $process.StandardInput.WriteLine(
                '{"jsonrpc":"2.0","id":' + ($index + 2) + ',"method":"ping"}')
            $process.StandardInput.Flush()
            $lineTask = $process.StandardOutput.ReadLineAsync()
            if (-not $lineTask.Wait(20000)) {
                throw "the server stopped answering after $answered pings"
            }
            ++$answered
        }
        $process.Refresh()
        $final = $process.HandleCount
    } finally {
        try { $process.StandardInput.Close() } catch { }
        if (-not $process.WaitForExit(15000)) {
            $process.Kill()
            $process.WaitForExit(5000)
        }
        $process.Dispose()
    }
    return [pscustomobject]@{ Answered = $answered; Baseline = $baseline; Final = $final }
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
$savedUserProfile = $env:USERPROFILE
$savedLocation = (Get-Location).Path

$env:LOCALAPPDATA = Join-Path $sandbox 'local'
$env:APPDATA = Join-Path $sandbox 'appdata'
$env:COPILOT_HOME = Join-Path $sandbox 'copilot'
# Every client has to land inside the sandbox, not just the ones that resolve
# their config from LOCALAPPDATA/APPDATA: Cursor and Windsurf hang off
# USERPROFILE and the VS Code entry is written into the working directory.
# Without these two the uninstall loop reaches into the real profile, and a
# check that is documented as non-destructive would be reading and comparing
# configurations it has no business touching.
$env:USERPROFILE = Join-Path $sandbox 'userprofile'
New-Item -ItemType Directory -Path $env:LOCALAPPDATA, $env:APPDATA, $env:COPILOT_HOME, $env:USERPROFILE -Force |
    Out-Null
Set-Location -LiteralPath $sandbox

$installDirectory = Join-Path $env:LOCALAPPDATA 'Programs\machine-env-cpp'
$script:Server = Join-Path $installDirectory 'machine-env-cpp.exe'
$configPath = Join-Path $env:COPILOT_HOME 'mcp-config.json'

try {
    Write-Step 'Install into a throwaway profile'
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'install.ps1') -SkipBuild
    if ($LASTEXITCODE -ne 0) { throw "install failed with exit code $LASTEXITCODE" }

    Write-Step 'Installed layout'
    Assert-That (Test-Path -LiteralPath $script:Server) 'server executable installed'
    Assert-That (Test-Path -LiteralPath $configPath) 'global MCP config written'
    $configured = (Get-Content -LiteralPath $configPath -Encoding UTF8 -Raw |
        ConvertFrom-Json).mcpServers.'machine-env-cpp'.command
    Assert-That ($configured -eq $script:Server) 'config points at the installed executable'
    # The rule travels only through the initialize result now, so the install must
    # not scatter instruction files into the harness instruction folders.
    $strayRules = @(Get-ChildItem -LiteralPath $env:APPDATA, $env:COPILOT_HOME `
            -Recurse -Filter 'machine-env-cpp.instructions.md' -ErrorAction SilentlyContinue)
    Assert-That ($strayRules.Count -eq 0) 'installation leaves no instruction file behind'

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
    # The initialize result is the only route the rule takes, so there is nothing
    # left to compare it against. The check is that it is still substantial and
    # still carries the obligations it exists for, which is what a truncated or
    # emptied rule would break. Clauses are built from code points so the script
    # cannot break on code page changes.
    function ConvertFrom-CodePoints([int[]]$Codes) {
        -join ($Codes | ForEach-Object { [char]$_ })
    }
    $injected = ([string]$byId['1'].result.instructions).Trim()
    $clauseMarker = ConvertFrom-CodePoints 0x8C03, 0x7528, 0x4E4B, 0x95F4, 0x82E5, 0x6709, 0x4F9D, 0x8D56
    $forbidWord = ConvertFrom-CodePoints 0x4E0D, 0x8981
    $adviceWord = ConvertFrom-CodePoints 0x5EFA, 0x8BAE
    $roundWord = ConvertFrom-CodePoints 0x5206, 0x8F6E
    $sendWord = ConvertFrom-CodePoints 0x53D1, 0x9001
    $softeners = [ordered]@{
        (ConvertFrom-CodePoints 0x5EFA, 0x8BAE) = 'suggests'
        (ConvertFrom-CodePoints 0x53EF, 0x4EE5) = 'permits'
        (ConvertFrom-CodePoints 0x8003, 0x8651) = 'invites consideration'
    }
    # A keyword proves the topic survived; it cannot tell an obligation from a
    # suggestion. The dependency rule is the one clause whose whole value is that
    # it forbids something, so it is checked in its imperative form: "not in the
    # same batch, send in separate rounds". Softened to advice ("consider sending
    # separately") the keyword would still match and the rule would be gone.
    #
    # This is a function rather than a run of assertions because it also has to
    # be run against text that is deliberately broken. An assertion nobody has
    # ever seen fail is a claim, not a test: this block once had an empty-clause
    # hole that made all three of its vocabulary checks pass on nothing at all,
    # and nothing in the suite would have found it. The list of problems, not a
    # sequence of throws, is what makes that possible.
    function Get-RuleProblems([string]$Text) {
        $problems = New-Object System.Collections.Generic.List[string]
        if ($Text.Length -le 100) { $problems.Add('rule-truncated') }
        $obligations = [ordered]@{
            (ConvertFrom-CodePoints 0x672C, 0x673A, 0x73AF, 0x5883, 0x5FC5, 0x987B, 0x5B9E, 0x6D4B) = 'measure-the-machine'
            (ConvertFrom-CodePoints 0x5148, 0x67E5) = 'consult-first'
            (ConvertFrom-CodePoints 0x53EA, 0x8BFB) = 'read-only'
            (ConvertFrom-CodePoints 0x4E0D, 0x4E0B, 0x8F7D) = 'no-downloads'
            ((ConvertFrom-CodePoints 0x4E0D, 0x652F, 0x6301) + ' &&') = 'shell-constraint'
            'source=unknown' = 'unknown-source'
            (ConvertFrom-CodePoints 0x6709, 0x4F9D, 0x8D56) = 'dependent-rounds'
        }
        foreach ($obligation in $obligations.Keys) {
            if (-not $Text.Contains([string]$obligation)) {
                $problems.Add('missing-' + $obligations[$obligation])
            }
        }
        $prohibition = $forbidWord + '[^' + [char]0x3002 + ']{0,24}' + $roundWord
        if (-not ($Text -match $prohibition)) { $problems.Add('dependency-softened') }
        # Slicing from the clause's own first word keeps the vocabulary check off
        # the rest of the rule, where those words are harmless.
        $clauseStart = $Text.LastIndexOf($clauseMarker)
        if ($clauseStart -lt 0) {
            $problems.Add('dependency-clause-missing')
            # With no clause the slice would be empty, and an empty slice
            # contains no forbidden word. Stopping here is what closes that hole.
            return $problems
        }
        $clause = $Text.Substring($clauseStart)
        if (-not $clause.Contains($roundWord)) { $problems.Add('clause-names-no-action') }
        if (-not $clause.Contains($sendWord)) { $problems.Add('clause-does-not-say-send') }
        foreach ($softener in $softeners.Keys) {
            if ($clause.Contains([string]$softener)) { $problems.Add('softened-to-advice') }
        }
        return $problems
    }
    $ruleProblems = @(Get-RuleProblems $injected)
    $problemList = if ($ruleProblems.Count -eq 0) { '' } else { ' (problems: ' + ($ruleProblems -join ', ') + ')' }
    Assert-That ($ruleProblems.Count -eq 0) ('the initialize rule carries every obligation, still forbids rather than advises, and its clause still names the action' + $problemList)
    # The checker only earns trust by biting. Each mutation below is a way this
    # rule could be lost while the script stayed green, applied to the real text
    # rather than to a fixture -- a fixture would test the fixture. Every mutation
    # must both change the text and be caught: a mutation the source no longer
    # contains proves nothing, and would otherwise pass in silence.
    $clauseAt = $injected.LastIndexOf($clauseMarker)
    $mutations = @(
        @{ Name = 'the prohibition is softened into a suggestion'
           Text = $injected.Replace($forbidWord, $adviceWord)
           Expect = 'dependency-softened' },
        @{ Name = 'the dependency clause is deleted outright'
           Text = if ($clauseAt -ge 0) { $injected.Substring(0, $clauseAt) } else { $injected }
           Expect = 'dependency-clause-missing' },
        @{ Name = 'the rule is emptied'
           Text = ''
           Expect = 'rule-truncated' }
    )
    foreach ($mutation in $mutations) {
        Assert-That ($mutation.Text -ne $injected) "the self-test can still break the rule when $($mutation.Name)"
        $caught = @(Get-RuleProblems $mutation.Text)
        Assert-That ($caught -contains $mutation.Expect) "the checker catches it when $($mutation.Name) (reported: $(if ($caught.Count -eq 0) { 'nothing' } else { $caught -join ', ' }))"
    }
    # The table is itself a thing that can be emptied: delete every row and the
    # loop above runs zero times and the suite stays green -- the same hole one
    # level up. So the table is held to the standard it exists to enforce: one
    # mutation per hole class, named by the problem it must produce. A fourth
    # mutation is welcome; losing one is not.
    $holeClasses = @('dependency-softened', 'dependency-clause-missing', 'rule-truncated')
    foreach ($hole in $holeClasses) {
        $covered = @($mutations | Where-Object { $_.Expect -eq $hole }).Count
        Assert-That ($covered -ge 1) "the self-test still has a mutation that trips $hole"
    }
    Assert-That ((@($mutations | ForEach-Object { $_.Name } | Sort-Object -Unique)).Count -eq @($mutations).Count) 'no two self-test mutations share a name'

    Write-Step 'Protocol edges'
    $handshake = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}'
    # A notification carries no id and must not be answered: a reply would hand
    # the client a response to a request it never made.
    $notified = Invoke-Stdio @(
        $handshake,
        '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"get_system","arguments":{}}}'
    )
    Assert-That (@($notified).Count -eq 1) 'a notification is not answered'
    # A line that is not JSON must be refused rather than dropped in silence.
    $broken = Invoke-Stdio @($handshake, '{not json}')
    Assert-That (@($broken)[1].error.code -eq -32700) 'a malformed line is refused with -32700'
    $unknownMethod = Invoke-Stdio @($handshake, '{"jsonrpc":"2.0","id":9,"method":"bogus/method"}')
    Assert-That (@($unknownMethod)[1].error.code -eq -32601) 'an unknown method is refused with -32601'
    # The client proposes a version and the server answers with one it supports,
    # so a client that asks for something else is not told it got it.
    $negotiated = Invoke-Stdio @('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1.0"}}')
    Assert-That (@($negotiated)[0].result.protocolVersion -ne '1.0') 'an unsupported protocol version is not echoed back'

    # The size limit has to hold while the message is being read, not after it
    # has been buffered: the point is to refuse an oversized message without ever
    # holding it in full. Reading in blocks must not lose that, and the stream
    # must still be positioned at the next message afterwards.
    $oversizedLine = '{"jsonrpc":"2.0","id":9,"method":"ping","params":{"pad":"' + ('x' * 9000000) + '"}}'
    $afterOversized = Invoke-Stdio @($oversizedLine, '{"jsonrpc":"2.0","id":10,"method":"ping"}')
    Assert-That ($afterOversized[0].error.code -eq -32600) 'an oversized message is refused, not buffered'
    Assert-That ([string]$afterOversized[0].error.message -match '8 MiB') 'the refusal names the limit'
    Assert-That ($afterOversized[1].id -eq 10) 'the message after an oversized one is still read'

    Write-Step 'Response contract'
    # Every call must carry a structured body, not only a detail=true one. A
    # caller that had to choose between a readable answer and a parseable one
    # ended up requesting detail for everything and paying for it in transcript.
    foreach ($tool in @('get_system', 'get_tools', 'get_apps', 'get_network')) {
        $plain = (Invoke-Stdio @('{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"' + $tool + '","arguments":{}}}'))[0].result
        $body = $plain.structuredContent
        Assert-That ($null -ne $body -and @($body.PSObject.Properties).Count -gt 0) "$tool returns structured content without detail=true"
        Assert-That ($plain._meta.tool -eq $tool) "$tool reports itself in _meta"
        Assert-That ($plain._meta.elapsed_ms -ge 0) "$tool reports its elapsed time"
        Assert-That ($plain._meta.brief_payload_bytes -gt 0) "$tool reports how large the text it returned is"
        Assert-That ([string]$plain.content[0].text -notmatch '^\s*\{') "$tool still answers in prose when detail is not set"
    }
    # The injected rule is the primary route, but a harness that drops it must
    # still see the constraint where every client does look.
    $descriptions = (Invoke-Stdio @($handshake, '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'))[1].result.tools
    foreach ($tool in $descriptions) {
        Assert-That ([string]$tool.description -match 'Read-only') "$($tool.name) states the read-only constraint in its own description"
    }

    Write-Step 'Application paging'
    # A page is a slice, never the inventory: count keeps meaning the total, and
    # page records what the slice covers so a page cannot be read as the whole.
    $allAppsForPaging = (Invoke-Stdio @('{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_apps","arguments":{"detail":true}}}'))[0].result.structuredContent
    $page1 = (Invoke-Stdio @('{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_apps","arguments":{"detail":true,"limit":2,"offset":0}}}'))[0].result.structuredContent
    Assert-That (@($page1.apps).Count -eq 2) 'a limit returns that many applications'
    Assert-That ($page1.count -eq $allAppsForPaging.count) 'the inventory total survives a page'
    Assert-That ($page1.page.returned -eq 2) 'the page reports how many it returned'
    Assert-That ($page1.page.available -eq $allAppsForPaging.count) 'the page reports how many it drew from'
    $page2 = (Invoke-Stdio @('{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_apps","arguments":{"detail":true,"limit":2,"offset":2}}}'))[0].result.structuredContent
    $first1 = @($page1.apps)[0].name
    $first2 = @($page2.apps)[0].name
    Assert-That ($first1 -ne $first2) 'an offset moves the window'
    # Out-of-range values are clamped rather than refused, and a wrong type is an
    # error rather than a silent default.
    $clamped = (Invoke-Stdio @('{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_apps","arguments":{"detail":true,"limit":99999}}}'))[0].result.structuredContent
    Assert-That ($clamped.page.limit -eq 1000) 'an oversized page is clamped'
    $badLimit = (Invoke-Stdio @('{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_apps","arguments":{"limit":"many"}}}'))[0]
    Assert-That ($badLimit.error.code -eq -32602) 'a non-integer limit is rejected'
    # A page is cut out of the matches, not out of the inventory: filtering after
    # paging made filter+limit answer "no match" while the inventory had matches.
    # A filter that matches nothing must leave nothing available to page through.
    $noMatchPage = (Invoke-Stdio @('{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_apps","arguments":{"filter":"zzz-no-such-app-xyz","limit":2,"offset":1}}}'))[0].result.structuredContent
    Assert-That ($noMatchPage.page.available -eq 0) 'a page is cut out of the matches rather than the inventory'
    Assert-That ($noMatchPage.page.returned -eq 0) 'a filter that matches nothing returns no page'

    Write-Step 'Detailed app filter'
    # A detailed result hands the payload back, so a filter that only shaped the
    # summary used to be accepted and then ignored: the caller asked for a subset
    # and received the whole inventory in hand instead.
    $allApps = (Invoke-Stdio @('{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_apps","arguments":{"detail":true}}}'))[0].result.structuredContent
    Assert-That (@($allApps.apps).Count -eq $allApps.count) 'an unfiltered detailed result lists the whole inventory'
    $noMatch = (Invoke-Stdio @('{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_apps","arguments":{"detail":true,"filter":"zzz-no-such-app-xyz"}}}'))[0].result.structuredContent
    Assert-That (@($noMatch.apps).Count -eq 0) 'a detailed result honours a filter that matches nothing'
    Assert-That ($noMatch.count -eq $allApps.count) 'the inventory total survives a filter'

    Write-Step 'Tool lookup outside the probed catalog'
    # A requested name the catalog does not probe must be answered rather than
    # omitted: an empty answer is read as "not present".
    $lookup = (Invoke-Stdio @('{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_tools","arguments":{"name":"no-such-tool-xyz"}}}'))[0]
    Assert-That ($lookup.result.content[0].text.Contains('NO-SUCH-TOOL-XYZ = ')) 'a name outside the probed catalog is answered rather than omitted'
    # A space separates tool names instead of joining a phrase, because a tool
    # name is a single token: "cmake ninja" asks for both. Treating it as one
    # phrase matched nothing and silently fell back to the whole catalog, so a
    # multi-word request is asserted on names that cannot be installed, which
    # keeps this check independent of what this machine happens to have.
    $split = (Invoke-Stdio @('{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_tools","arguments":{"name":"zz-split-a zz-split-b"}}}'))[0].result.content[0].text
    Assert-That ($split.Contains('ZZ-SPLIT-A = ')) 'a space-separated name list answers the first name'
    Assert-That ($split.Contains('ZZ-SPLIT-B = ')) 'a space-separated name list answers the second name'
    # A filter that matches nothing must say so instead of returning silence.
    # Under the split rule each requested name is answered in turn, so "says so"
    # means every name comes back, not that the input is echoed whole.
    $phrase = (Invoke-Stdio @('{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_tools","arguments":{"name":"zz-none-a zz-none-b zz-none-c"}}}'))[0].result.content[0].text
    Assert-That (-not [string]::IsNullOrWhiteSpace($phrase)) 'a filter that matches nothing is not silence'
    foreach ($token in @('ZZ-NONE-A', 'ZZ-NONE-B', 'ZZ-NONE-C')) {
        Assert-That ($phrase.Contains("$token = ")) "a filter that matches nothing still answers '$token'"
    }

    Write-Step 'Visual Studio detection contract'
    # "Could not look", "looked and found nothing" and "found it" are three
    # different answers. vswhere also hides pre-release channels, so an empty
    # answer only means absent when the query covered every instance.
    $toolchainResponse = (Invoke-Stdio @('{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_tools","arguments":{"detail":true,"refresh":true}}}'))[0]
    $toolchain = $toolchainResponse.result.structuredContent
    $toolchainText = [string]$toolchainResponse.result.content[0].text
    $detection = [string]$toolchain.vs_detection
    Assert-That ($detection -in @('ok', 'absent', 'unknown')) "vs_detection is one of ok/absent/unknown (got '$detection')"
    Assert-That (($detection -ne 'ok') -or ($toolchain.vs_path.Length -gt 0)) 'a detected Visual Studio comes with the path it was found at'
    Assert-That (($detection -eq 'ok') -or ($toolchain.vs_path.Length -eq 0)) 'a path is not left behind by a detection that did not succeed'
    # A locator that exists and runs answers the question either way, so it must
    # never leave the result indeterminate: that was the label inversion, where a
    # completed query that matched nothing was reported as an unfinished one.
    $pf86 = ${env:ProgramFiles(x86)}
    if (-not $pf86) { $pf86 = 'C:\Program Files (x86)' }
    $vswhere = Join-Path $pf86 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $vswhere) {
        Assert-That ($detection -ne 'unknown') 'a usable locator never reports the answer as indeterminate'
    }
    # The warning is only honest when the look itself failed; printing it after a
    # completed query reports a successful probe as an incomplete one.
    $vsWarning = -join ([char]0x68C0, [char]0x6D4B, [char]0x672A, [char]0x5B8C, [char]0x6210)
    Assert-That ($toolchainText.Contains($vsWarning) -eq ($detection -eq 'unknown')) 'the Visual Studio warning appears only when the look itself failed'

    Write-Step 'Tool resolution contract'
    # "Where is python" means the python the bare name runs. Answering from an
    # install directory that PATH does not reach, and then flagging that copy as
    # not on PATH, is two true facts that together describe an interpreter the
    # caller will never run -- and it made the pip that does run look like it
    # belonged to a different installation.
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $composedPath = (@($machinePath, $userPath) | Where-Object { $_ }) -join ';'
    $onPathPython = $null
    foreach ($directory in ($composedPath -split ';')) {
        if ([string]::IsNullOrWhiteSpace($directory)) { continue }
        $candidate = Join-Path $directory 'python.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $onPathPython = $candidate
            break
        }
    }
    if ($onPathPython -and $onPathPython -notmatch 'WindowsApps') {
        $reportedPython = [System.IO.Path]::GetFullPath([string]$toolchain.tools.python)
        $expectedPython = [System.IO.Path]::GetFullPath($onPathPython)
        Assert-That ([string]::Equals($reportedPython, $expectedPython,
                                       [System.StringComparison]::OrdinalIgnoreCase)) `
            'the reported python is the one the bare name runs'
        Assert-That (-not (@($toolchain.not_on_path) -contains 'python')) 'a python that PATH reaches is not flagged as off PATH'
    } else {
        Write-Host '   --  no python on PATH outside WindowsApps, so the PATH-first rule is not exercised here' -ForegroundColor DarkGray
    }
    if ($toolchain.tools.python) {
        Assert-That (Test-Path -LiteralPath $toolchain.tools.python) 'a reported python path exists on disk'
        Assert-That ($toolchain.python_root -eq (Split-Path -Parent ([string]$toolchain.tools.python))) 'python_root is the directory of the reported python'
    }
    if ($toolchain.tools.pip) {
        Assert-That (Test-Path -LiteralPath $toolchain.tools.pip) 'a reported pip path exists on disk'
    }
    if ($toolchain.tools.pip -and $toolchain.python_root) {
        $pipBesidePython = Join-Path $toolchain.python_root 'Scripts\pip.exe'
        if ([string]::Equals([System.IO.Path]::GetFullPath([string]$toolchain.tools.pip),
                             [System.IO.Path]::GetFullPath($pipBesidePython),
                             [System.StringComparison]::OrdinalIgnoreCase)) {
            Assert-That ($toolchain.python_pip_mismatch -eq $false) 'a pip beside the reported python is not called a mismatch'
        }
    }

    Write-Step 'Detailed tool filter'
    # A detailed result hands the probed payload back, so a name filter that only
    # shaped the summary used to be accepted and then ignored: asking for one
    # tool still returned the whole catalog in hand (E02). The filter now narrows
    # the payload, and the related maps have to shrink in step so a tool cannot
    # survive in "tools" while vanishing from "versions".
    $catalogNames = @($toolchain.tools.PSObject.Properties.Name)
    if ($catalogNames.Count -gt 1) {
        $requested = $catalogNames[0]
        # Versions are opt-in now, so a narrowing test that means anything has to
        # ask for them: without the flag the version map is empty and the check
        # would pass by having nothing to check.
        $single = (Invoke-Stdio @('{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_tools","arguments":{"detail":true,"include_versions":true,"name":"' + $requested + '"}}}'))[0].result.structuredContent
        $singleNames = @($single.tools.PSObject.Properties.Name)
        Assert-That ($singleNames -contains $requested) 'a detailed result keeps the tool that was requested'
        Assert-That ($singleNames.Count -lt $catalogNames.Count) 'a detailed result narrows the catalog to the filter'
        Assert-That ($single.tool_count -eq $toolchain.tool_count) 'the catalog total survives a name filter'
        # A total with no matching number beside it reads as a contradiction
        # (20 next to a single entry), so the filtered size is stated as its own
        # field instead of the total being redefined under the reader's feet.
        Assert-That ($single.matched_count -eq $singleNames.Count) 'a filtered result reports how many it matched'
        # A null property name is not an entry: an empty map yields $null from
        # .Name, and @($null) is a one-element array, which used to read as an
        # orphan that was not there.
        $versionNames = @($single.versions.PSObject.Properties.Name | Where-Object { $_ })
        $orphans = @($versionNames | Where-Object { $singleNames -notcontains $_ })
        Assert-That ($orphans.Count -eq 0) 'no version entry outlives the tool it describes'
    } else {
        Write-Host '   SKIP  fewer than two probed tools to narrow on' -ForegroundColor DarkYellow
    }
    # Even when nothing matches, the total stays the size of the catalog: it is
    # the whole the subset was drawn from, not the size of the subset.
    $nothing = (Invoke-Stdio @('{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_tools","arguments":{"detail":true,"name":"zz-no-such-tool-xyz"}}}'))[0].result.structuredContent
    Assert-That (@($nothing.tools.PSObject.Properties).Count -eq 0) 'a detailed result honours a filter that matches nothing'
    Assert-That ($nothing.tool_count -eq $toolchain.tool_count) 'the catalog total survives a filter that matches nothing'
    Assert-That ($nothing.matched_count -eq 0) 'a filter that matches nothing reports zero matched'
    # The mismatch flag is a comparison between two entries. With pip filtered
    # out it can no longer be judged, and reporting false would claim they agree.
    if ($toolchain.tools.pip) {
        $pythonOnly = (Invoke-Stdio @('{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_tools","arguments":{"detail":true,"name":"python"}}}'))[0].result.structuredContent
        Assert-That (-not $pythonOnly.tools.PSObject.Properties.Name.Contains('pip')) 'filtering to python leaves pip out of the payload'
        Assert-That ($null -eq $pythonOnly.python_pip_mismatch) 'a mismatch is not asserted about a pip that is not in the payload'
    }

    Write-Step 'Tool version opt-in'
    # Reading a version means running the tool: one child process per tool, which
    # is what made this call cost ~1.3s. It is opt-in, and the two answers are
    # cached apart so the fast payload can never satisfy a request for versions.
    # Both halves arrive in one call now, so the summary is checked on the same
    # response the structured body comes from.
    $fast = (Invoke-Stdio @('{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_tools","arguments":{"refresh":true}}}'))[0].result
    $fastBody = $fast.structuredContent
    Assert-That ($fastBody.versions_included -eq $false) 'versions are not read unless asked for'
    Assert-That (@($fastBody.versions.PSObject.Properties).Count -eq 0) 'an unversioned probe carries no versions'
    Assert-That ([string]$fast.content[0].text -match 'include_versions') 'the summary says versions were not queried'
    Assert-That ($fast._meta.elapsed_ms -lt 1200) 'locating tools without running them stays well under a second'
    $withVersions = (Invoke-Stdio @('{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_tools","arguments":{"refresh":true,"include_versions":true,"detail":true}}}'))[0].result.structuredContent
    Assert-That ($withVersions.versions_included -eq $true) 'versions are read when asked for'
    Assert-That ($withVersions.tool_count -eq $fastBody.tool_count) 'asking for versions does not change which tools were found'
    # Served from cache this time, and the cached unversioned entry must not be
    # what answers it.
    $fromCache = (Invoke-Stdio @('{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_tools","arguments":{"include_versions":true,"detail":true}}}'))[0].result.structuredContent
    Assert-That ($fromCache.versions_included -eq $true) 'a request for versions is never served the unversioned cache entry'

    Write-Step 'Network timeout contract'
    # A host blackholed at the DNS layer stalls the resolver past every
    # per-phase WinHTTP timeout, so the call is bounded by a wall-clock budget
    # and anything still unanswered is reported as over budget. offline is the
    # deterministic way to check the plumbing: every endpoint is skipped, so the
    # probe never touches the network while still reporting the budget in force.
    $offline = (Invoke-Stdio @('{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_network","arguments":{"offline":true,"detail":true}}}'))[0].result.structuredContent
    Assert-That ($offline.budget_ms -eq 2500) 'a network probe reports its budget'
    Assert-That ($offline.offline -eq $true) 'offline is recorded on the result'
    $entries = @($offline.endpoints.PSObject.Properties)
    $skippedEntries = @($entries | Where-Object { $_.Value.skipped -eq $true })
    Assert-That ($entries.Count -gt 0 -and $skippedEntries.Count -eq $entries.Count) 'offline skips every endpoint'
    Assert-That (@($skippedEntries | Where-Object { $_.Value.reason -ne 'offline' }).Count -eq 0) 'a skipped endpoint records why'
    # The budget window belongs to a summary that reports endpoints over budget.
    # With every endpoint skipped there is nothing over budget, so the offline
    # summary must not state one -- and a reader who sees a window there would be
    # reading a promise about a probe that never happened.
    #
    # The negative half is checked together with its positive half on purpose: a
    # summary that lost its budget sentence everywhere would satisfy "offline
    # states none" while telling every other caller nothing. The offline form is
    # asserted first so an empty or truncated summary cannot pass as a clean one.
    $windowPattern = (ConvertFrom-CodePoints 0x9884, 0x7B97) + '\s*\d+\s*ms'
    $proseOffline = [string](Invoke-Stdio @('{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_network","arguments":{"offline":true}}}'))[0].result.content[0].text
    Assert-That ($proseOffline.Length -gt 20 -and $proseOffline -match ((ConvertFrom-CodePoints 0x5168, 0x90E8, 0x7AEF, 0x70B9, 0x5DF2, 0x8DF3, 0x8FC7))) 'an offline probe still describes itself rather than returning a blank summary'
    Assert-That ($proseOffline -notmatch $windowPattern) 'an offline summary does not state a budget window for endpoints it never tried'
    # The other half of that pair, on a budget tight enough that endpoints really
    # do run out: whenever a summary reports one over budget it has to say which
    # budget. This is an implication rather than a flat expectation because a
    # host fast enough to finish four endpoints inside the floor would make a
    # flat expectation fail for a reason that is not a defect. When that happens
    # the line reports SKIP, not OK -- a check that silently did nothing is worse
    # than one that says so.
    $proseTight = [string](Invoke-Stdio @('{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_network","arguments":{"refresh":true,"timeout_ms":1}}}'))[0].result.content[0].text
    $overBudgetWord = ConvertFrom-CodePoints 0x8D85, 0x8FC7, 0x9884, 0x7B97
    if ($proseTight.Contains($overBudgetWord)) {
        Assert-That ($proseTight -match $windowPattern) 'a summary that reports an endpoint over budget also states which budget ran out'
    } else {
        Write-Host '   SKIP a summary that reports an endpoint over budget also states which budget ran out (this host finished every endpoint inside the floor budget; the implication had no subject)' -ForegroundColor DarkYellow
    }
    # Out-of-range budgets are clamped rather than rejected: a rejected call
    # would cost the caller the whole answer instead of the nearest budget.
    $floor = (Invoke-Stdio @('{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_network","arguments":{"offline":true,"timeout_ms":1,"detail":true}}}'))[0].result.structuredContent
    Assert-That ($floor.budget_ms -eq 200) 'a budget below the floor is clamped'
    $ceiling = (Invoke-Stdio @('{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_network","arguments":{"offline":true,"timeout_ms":999999,"detail":true}}}'))[0].result.structuredContent
    Assert-That ($ceiling.budget_ms -eq 10000) 'a budget above the ceiling is clamped'
    # A wrong type is an error, not a silent fallback to the default budget.
    $badBudget = (Invoke-Stdio @('{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_network","arguments":{"timeout_ms":"fast"}}}'))[0]
    Assert-That ($badBudget.error.code -eq -32602) 'a non-integer budget is rejected'
    # The argument only helps if a client can discover it.
    $networkTool = @((Invoke-Stdio @($handshake, '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'))[1].result.tools |
            Where-Object { $_.name -eq 'get_network' })[0]
    $budgetSchema = $networkTool.inputSchema.properties.timeout_ms
    Assert-That ($null -ne $budgetSchema) 'the schema advertises timeout_ms'
    Assert-That ($budgetSchema.minimum -eq 200 -and $budgetSchema.maximum -eq 10000) 'the schema carries the budget bounds'

    Write-Step 'Shared argument descriptions'
    # Four tools take `refresh`, and the warning it carries is a timing promise
    # rather than a synonym for "re-probe". Four copies of that text drift; one
    # constant cannot. Equality across all four is the check that catches a tool
    # being added with a weaker description of its own.
    $catalog = @((Invoke-Stdio @($handshake, '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'))[1].result.tools)
    $refreshTexts = @()
    foreach ($entry in $catalog) {
        $property = $entry.inputSchema.properties.refresh
        if ($null -ne $property) { $refreshTexts += [string]$property.description }
    }
    # The count is deliberately not asserted. "Four tools take refresh" is a fact
    # that silently stops being true the day a fifth tool is added, and an
    # assertion that pins 4 would then be "fixed" by editing the 4 -- which is
    # how a real check turns into noise. What matters is that every tool that
    # takes refresh says the same thing, and that at least one does.
    Assert-That ($refreshTexts.Count -ge 1) 'at least one tool takes refresh'
    Assert-That ((@($refreshTexts | Sort-Object -Unique)).Count -eq 1) "every tool describes refresh the same way (got $($refreshTexts.Count) tools, $(@($refreshTexts | Sort-Object -Unique).Count) description)"
    # Saying "will not see the new value" is what makes the warning usable; a
    # version that only says "re-probe" leaves the race undisclosed.
    Assert-That ([string]$refreshTexts[0]).Contains('will not see the new value') 'the refresh description discloses what a batched reader can see'
    Assert-That ([string]$refreshTexts[0]).Contains('coalesced') 'the refresh description says a repeat inside the interval is coalesced'
    # The window is formatted from the constant, so the sentence cannot drift
    # from the behaviour; what is asserted here is that the number is still a
    # usable one. It is stated in milliseconds on purpose: any unit that has to
    # be rounded turns a 2500 ms setting into "2 seconds", and a description that
    # rounds is a description that lies by a little.
    Assert-That ([string]$refreshTexts[0] -match 'within [1-9]\d* ms') 'the refresh description states a positive coalescing window in milliseconds'

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

    Write-Step 'Cache housekeeping'
    # A write removes its own temporary file when it fails, but nothing runs
    # after a kill, so each interrupted write leaves one behind and nothing
    # collects them: one stress run left 4384 orphans and 292 MB beside six real
    # entries under 20 KB. The sweep is bounded by age so a live write -- the
    # temp of a concurrent install -- is never touched.
    $cacheDir = Split-Path -Parent $cacheFile
    $staleTemp = Join-Path $cacheDir 'system.json.999-1.tmp'
    $freshTemp = Join-Path $cacheDir 'apps.json.999-2.tmp'
    [System.IO.File]::WriteAllText($staleTemp, '{"abandoned":true}')
    [System.IO.File]::WriteAllText($freshTemp, '{"in-flight":true}')
    (Get-Item -LiteralPath $staleTemp).LastWriteTime = (Get-Date).AddHours(-2)
    $null = Invoke-Stdio @($handshake, '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_apps","arguments":{"detail":true}}}')
    Assert-That (-not (Test-Path -LiteralPath $staleTemp)) 'an abandoned temporary file is swept at startup'
    Assert-That (Test-Path -LiteralPath $freshTemp) 'a temporary file younger than the age guard is left alone'
    Assert-That (Test-Path -LiteralPath $cacheFile) 'a sweep does not touch a real cache entry'
    [System.IO.File]::Delete($freshTemp)

    Write-Step 'Concurrent request handling'
    # Requests are executed concurrently but answered in the order they were
    # asked. Order is the part a client can be broken by, so it is asserted;
    # the latency gain is a consequence, not a contract.
    $burst = Invoke-Stdio @(
        $handshake,
        '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_apps","arguments":{}}}',
        '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_tools","arguments":{}}}',
        '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_system","arguments":{}}}',
        '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"get_network","arguments":{"offline":true}}}'
    )
    Assert-That (@($burst).Count -eq 5) 'a pipelined burst gets one answer per request'
    $answeredOrder = (@($burst) | ForEach-Object { [string]$_.id }) -join ','
    Assert-That ($answeredOrder -eq '1,2,3,4,5') "a pipelined burst is answered in request order (got $answeredOrder)"
    # A refresh inside the minimum interval is answered from the entry a previous
    # probe just wrote, and says so, instead of repeating the probe.
    $probed = (Invoke-Stdio @($handshake, '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_apps","arguments":{"refresh":true}}}'))[1].result
    $coalesced = (Invoke-Stdio @($handshake, '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_apps","arguments":{"refresh":true}}}'))[1].result
    Assert-That ($coalesced.structuredContent._cache.reason -eq 'refresh coalesced') 'a refresh inside the minimum interval is coalesced'
    Assert-That ($coalesced._meta.elapsed_ms -le $probed._meta.elapsed_ms) 'a coalesced refresh costs no more than the probe it replaces'
    Assert-That ($coalesced.structuredContent.count -gt 0) 'a coalesced refresh still returns the fact, not an empty answer'

    Write-Step 'Response ordering'
    # Order is best-effort: kept while the answer ahead is merely slower, given
    # up only after the window has passed. A client that positions answers
    # instead of correlating them by id can turn the window off entirely.
    $slowThenFast = @(
        $handshake,
        '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_network","arguments":{"refresh":true,"timeout_ms":2500}}}',
        '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_apps","arguments":{"limit":1}}}',
        '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_apps","arguments":{"limit":1}}}'
    )
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $ordered = Invoke-Stdio $slowThenFast
    $clock.Stop()
    $orderedIds = (@($ordered) | ForEach-Object { [string]$_.id }) -join ','
    if ($clock.ElapsedMilliseconds -gt 600) {
        Assert-That ($orderedIds -eq '1,3,4,2') "a slow answer does not hold back the ones behind it (got $orderedIds)"
    } else {
        Write-Host '   SKIP  the slow request finished too quickly to exercise the window' -ForegroundColor DarkYellow
    }
    $savedWindow = $env:MACHINE_ENV_REORDER_WINDOW_MS
    $env:MACHINE_ENV_REORDER_WINDOW_MS = '0'
    try {
        $strict = Invoke-Stdio $slowThenFast
        $strictIds = (@($strict) | ForEach-Object { [string]$_.id }) -join ','
        Assert-That ($strictIds -eq '1,2,3,4') "the window can be turned off for a position-based client (got $strictIds)"
        # A line that asks for nothing must not consume a position. When it did,
        # strict mode waited for an answer that could never come and the session
        # went silent after the blank line -- which is the failure a caller sees
        # as "the server hung", not as "the server skipped a line".
        $afterBlank = Invoke-Stdio @(
            '{"jsonrpc":"2.0","id":1,"method":"ping"}',
            '',
            '{"jsonrpc":"2.0","id":2,"method":"ping"}'
        )
        $blankIds = (@($afterBlank) | ForEach-Object { [string]$_.id }) -join ','
        Assert-That (@($afterBlank).Count -eq 2) "a blank line is not answered (got $(@($afterBlank).Count))"
        Assert-That ($blankIds -eq '1,2') "a blank line does not silence the rest of a strict session (got $blankIds)"
    } finally {
        if ($null -eq $savedWindow) {
            Remove-Item Env:MACHINE_ENV_REORDER_WINDOW_MS -ErrorAction SilentlyContinue
        } else {
            $env:MACHINE_ENV_REORDER_WINDOW_MS = $savedWindow
        }
    }

    Write-Step 'Per-response diagnostics'
    # The load harnesses read this line instead of the aggregate one, which is
    # rate limited to one report per five seconds and therefore reports zero for
    # any burst shorter than that.
    $savedDiag = $env:MACHINE_ENV_DIAG
    $env:MACHINE_ENV_DIAG = '1'
    try {
        $diagnosed = Invoke-LiveSession @(
            $handshake,
            '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_system","arguments":{"detail":true}}}'
        ) -ShowDiagnostics
        Assert-That (@($diagnosed).Count -eq 2) 'a diagnosed session still answers every request'
        $diagLine = (@($script:liveDiagnostics) | Where-Object { $_ -match 'tool=get_system' } |
            Select-Object -First 1)
        Assert-That ($null -ne $diagLine) 'the diagnostic line names the tool that was called'
        Assert-That ([string]$diagLine -match 'diag: seq=\d+ tool=get_system wait_ms=\d+ reordered=[01]') "the diagnostic line carries the sequence, the wait, and whether it was reordered (got '$diagLine')"
    } finally {
        if ($null -eq $savedDiag) {
            Remove-Item Env:MACHINE_ENV_DIAG -ErrorAction SilentlyContinue
        } else {
            $env:MACHINE_ENV_DIAG = $savedDiag
        }
    }

    Write-Step 'Live session'
    $live = @(Invoke-LiveSession @(
        $handshake,
        '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}',
        '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_apps","arguments":{"limit":1}}}'
    ))
    Assert-That (@($live).Count -eq 3) "a connected session gets one answer per request (got $($live.Count))"
    Assert-That ($live[0].result.serverInfo.name -eq 'machine-env-cpp') 'the handshake is answered while stdin is still open'
    $liveOrder = (@($live) | ForEach-Object { [string]$_.id }) -join ','
    Assert-That ($liveOrder -eq '1,2,3') "a connected session is answered in request order (got $liveOrder)"
    # The first request is written in two pieces with the pipe idle in between,
    # so a message is never assumed to arrive in one write.
    $splitLive = @(Invoke-LiveSession @($handshake) -SplitFirstAt 40)
    Assert-That ($splitLive[0].result.serverInfo.name -eq 'machine-env-cpp') 'a request split across two writes is still answered'
    # Serving a call must not cost a handle that lasts as long as the session.
    # 300 calls leave the pool at the size of what is in flight, not at 300,
    # so the bound below is generous on purpose: it fails a leak, not a nuance.
    $pool = Measure-LiveSessionHandles -Handshake $handshake -Count 300
    $poolGrowth = $pool.Final - $pool.Baseline
    Assert-That ($pool.Answered -eq 300) "a long session answers every call (got $($pool.Answered))"
    Assert-That ($poolGrowth -lt 80) "a long session does not hold a handle per call (grew by $poolGrowth over 300)"

    Write-Step 'Uninstall'
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $installDirectory 'uninstall-portable.ps1')
    if ($LASTEXITCODE -ne 0) { throw "uninstall failed with exit code $LASTEXITCODE" }
    $servers = (Get-Content -LiteralPath $configPath -Encoding UTF8 -Raw |
        ConvertFrom-Json).mcpServers
    Assert-That (($null -eq $servers) -or ($null -eq $servers.'machine-env-cpp')) 'config entry removed'
    Assert-That (-not (Test-Path -LiteralPath $installDirectory)) 'install directory removed'
    # The uninstaller loops over every supported client so a multi-client install
    # is fully undone. On a client that was never registered there is nothing to
    # remove, and it must say so instead of inventing a configuration file.
    $strayConfigs = @(
        (Join-Path $env:USERPROFILE '.cursor\mcp.json')
        (Join-Path $env:USERPROFILE '.codeium\windsurf\mcp_config.json')
        (Join-Path (Get-Location) '.vscode\mcp.json')
    ) | Where-Object { Test-Path -LiteralPath $_ }
    Assert-That ($strayConfigs.Count -eq 0) 'uninstalling creates no configuration for a client that was never registered'

    # The count is reported by the run rather than counted by whoever reads the
    # log. "We have N assertions" was a figure copied by hand from a scrollback,
    # which is how it goes stale the first time a block is merged.
    Write-Host "`nVERIFY: PASS ($script:assertionCount assertions)" -ForegroundColor Green
} finally {
    $env:LOCALAPPDATA = $savedLocalAppData
    $env:APPDATA = $savedAppData
    if ($null -eq $savedCopilotHome) {
        Remove-Item Env:COPILOT_HOME -ErrorAction SilentlyContinue
    } else {
        $env:COPILOT_HOME = $savedCopilotHome
    }
    $env:USERPROFILE = $savedUserProfile
    # The working directory has to leave the sandbox before the sandbox is
    # removed, or the removal fails because the directory is in use.
    Set-Location -LiteralPath $savedLocation
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}
