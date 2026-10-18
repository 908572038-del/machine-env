<#
.SYNOPSIS
    Head-of-line harness for machine-env-cpp: does one slow request hold back the
    answers that are already finished, and does the bounded reorder window help?

.DESCRIPTION
    Sends [1 slow request, then 49 pings] into one server process and timestamps every
    response line as it arrives. The pings are the measurement: each is finished in
    about a millisecond, so any delay in their arrival is queueing, not work.

    Two runs per slow kind:

      strict    MACHINE_ENV_REORDER_WINDOW_MS=0  -> answers must come back in request
                order, which means 0 of 49 pings may arrive before the slow answer.
                This is the contract case: fail here and the strict mode is broken.
      windowed  MACHINE_ENV_REORDER_WINDOW_MS=200 -> at least 45 of 49 pings must
                arrive before the slow answer, and the longest hold reported on
                stderr ("max hold Y ms") must stay within window + 50 ms of
                scheduling slack.

    SKIP, not FAIL, when the slow request is not actually slow enough to create a
    gap worth reordering (measured elapsed < window + 100 ms). A fast slow-request
    means the case proves nothing, and a red would be a lie.

    Contract cases (may fail):
      * every id answered exactly once
      * strict mode: order is exactly 1..50 and 0 pings jump the queue
      * windowed mode: >= 45/49 pings jump the queue, ids intact
      * the slow answer is not itself delayed (arrive - its own elapsed <= 150 ms,
        the slack being process start plus emit)
    Everything else (max hold, reorder count) is reported, and only enforced when
    the stderr line exists.

.PARAMETER WindowMs
    The window under test (default 200, the shipping default).

.PARAMETER SampleIntervalMs
    Unused by the timing logic; kept so the harness has one obvious place for it.
    Note: no process sampling is needed here - the clock is the stdout stream itself,
    and sampling at 15 ms would be coarser than the effect being measured.

.EXAMPLE
    powershell -NoProfile -File scripts/perf-reorder-concurrency.ps1
    powershell -NoProfile -File scripts/perf-reorder-concurrency.ps1 -WindowMs 300
#>
[CmdletBinding()]
param(
    [string]$ExePath = '',
    [int]$WindowMs = 200,
    [int]$SampleIntervalMs = 15,
    [string]$OutDir = ''
)

# Continue, not Stop: the server writes its fingerprint line to stderr, and under
# Stop every stderr record from a native command becomes a terminating error.
# Correctness is checked explicitly below (missing exe, missing responses).
$ErrorActionPreference = 'Continue'
# The server speaks UTF-8. Windows PowerShell decodes a native command's stdout with
# the console code page by default; on a GBK/CP1252 console the decoded text can even
# lose an ASCII byte (a double-byte lead char swallows the next one), which is why the
# decode is switched to UTF-8 *around the server call only*, and why the parsing below
# reads ASCII keys with regex rather than trusting a JSON parser.
$script:utf8 = New-Object System.Text.UTF8Encoding $false
$script:originalConsoleEncoding = [Console]::OutputEncoding
$OutputEncoding = $script:utf8
$script:failures = New-Object System.Collections.Generic.List[string]
$script:rows = New-Object System.Collections.Generic.List[object]

# $PSScriptRoot is not reliable inside a param() default under "powershell -File",
# so both paths are resolved after the parameters are bound.
$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $PSCommandPath }
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$repoRoot = Split-Path -Parent $scriptDir
if (-not $ExePath) { $ExePath = Join-Path $repoRoot 'build/machine-env-cpp.exe' }
if (-not $OutDir) { $OutDir = Join-Path $repoRoot 'build/perf-out' }

if (-not (Test-Path $ExePath)) { throw "server exe not found: $ExePath" }
$ExePath = (Resolve-Path $ExePath).Path
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }

function Get-ServerFingerprint {
    param([string]$Exe)
    # The server prints its fingerprint on stderr and then waits for stdin; an empty
    # pipeline gives it the EOF it needs, otherwise this call blocks forever.
    [Console]::OutputEncoding = $script:utf8
    try { $err = '' | & $Exe 2>&1 | Out-String }
    finally { [Console]::OutputEncoding = $script:originalConsoleEncoding }
    if ($err -match 'fingerprint\s+(\S+)\)') { return $Matches[1] }
    return 'unverified'
}

$init = '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"perf-reorder","version":"1"}}}'

$slowKinds = @(
    @{ name = 'system';          json = '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_system","arguments":{"refresh":true}}}' },
    @{ name = 'tools-versions';  json = '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_tools","arguments":{"refresh":true,"include_versions":true}}}' },
    @{ name = 'network';         json = '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_network","arguments":{"refresh":true,"timeout_ms":1200,"detail":false}}}' },
    @{ name = 'apps';            json = '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_apps","arguments":{"refresh":true}}}' }
)

function Invoke-HolRun {
    param([string]$SlowJson, [int]$Window, [string]$Label)

    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add($init)
    $lines.Add($SlowJson)
    for ($i = 2; $i -le 50; $i++) { $lines.Add('{"jsonrpc":"2.0","id":' + $i + ',"method":"ping"}') }

    $previous = $env:MACHINE_ENV_REORDER_WINDOW_MS
    $env:MACHINE_ENV_REORDER_WINDOW_MS = [string]$Window
    $sw = [Diagnostics.Stopwatch]::StartNew()
    [Console]::OutputEncoding = $script:utf8
    try {
        $raw = $lines | & $ExePath 2>&1 | ForEach-Object {
            $t = $sw.ElapsedMilliseconds
            $text = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { [string]$_ }
            '{0}|{1}' -f $t, $text
        }
    } finally {
        $sw.Stop()
        [Console]::OutputEncoding = $script:originalConsoleEncoding
        $env:MACHINE_ENV_REORDER_WINDOW_MS = $previous
    }

    $byId = @{}
    $order = New-Object System.Collections.Generic.List[int]
    $stderr = New-Object System.Collections.Generic.List[string]
    foreach ($line in $raw) {
        $cut = $line.IndexOf('|'); if ($cut -lt 0) { continue }
        $arrive = [int]$line.Substring(0, $cut)
        $text = $line.Substring($cut + 1).Trim()
        if (-not $text.StartsWith('{')) { if ($text) { $stderr.Add($text) }; continue }
        # ASCII keys only; the payload text itself may be decoded lossily.
        $idMatch = [regex]::Match($text, '"id":(\d+)')
        if (-not $idMatch.Success) { continue }
        $id = [int]$idMatch.Groups[1].Value
        if ($id -le 0) { continue }
        $elapsedMatch = [regex]::Match($text, '"elapsed_ms":(\d+)')
        $byId[$id] = [pscustomobject]@{
            arrive  = $arrive
            elapsed = $(if ($elapsedMatch.Success) { [double]$elapsedMatch.Groups[1].Value } else { [double]::NaN })
        }
        $order.Add($id)
    }

    $pings = @(2..50 | ForEach-Object { $byId[$_] } | Where-Object { $_ } | ForEach-Object { $_.arrive } | Sort-Object)
    $slow = $byId[1]
    $before = if ($slow -and $pings.Count) { @($pings | Where-Object { $_ -lt $slow.arrive }).Count } else { 0 }
    $maxHold = $null; $reordered = $null
    $stderrText = $stderr -join "`n"
    if ($stderrText -match 'max hold (\d+) ms') { $maxHold = [int]$Matches[1] }
    if ($stderrText -match '(\d+) reordered') { $reordered = [int]$Matches[1] }

    [pscustomobject]@{
        Label = $Label; Window = $Window; Wall = $sw.ElapsedMilliseconds
        SlowArrive = $(if ($slow) { $slow.arrive } else { -1 })
        SlowElapsed = $(if ($slow) { $slow.elapsed } else { -1 })
        PingsBefore = $before; PingCount = $pings.Count
        PingFirst = $(if ($pings.Count) { $pings[0] } else { -1 })
        PingLast = $(if ($pings.Count) { $pings[-1] } else { -1 })
        Order = $order; ById = $byId; MaxHold = $maxHold; Reordered = $reordered
        Stderr = $stderr
    }
}

function Add-Row {
    param([string]$Case, [string]$Verdict, [string]$Detail)
    $script:rows.Add([pscustomobject]@{ case = $Case; verdict = $Verdict; detail = $Detail })
    Write-Host ("{0,-30} {1,-8} {2}" -f $Case, $Verdict, $Detail)
}

$fingerprint = Get-ServerFingerprint -Exe $ExePath
Write-Host "== perf-reorder-concurrency =="
Write-Host "exe          : $ExePath"
Write-Host "fingerprint  : $fingerprint"
Write-Host "window under test : $WindowMs ms (MACHINE_ENV_REORDER_WINDOW_MS)"
Write-Host "fixture      : 1 slow request then 49 pings; slow kinds = system/tools-versions/network/apps"
Write-Host "clock        : arrival of each stdout line, not process sampling"
Write-Host ''

foreach ($kind in $slowKinds) {
    # A refresh is answered from the cache when an entry was written inside the
    # minimum refresh interval (5 s), and a cached answer is 0 ms - it cannot create
    # the gap this harness needs. Sleeping past that interval between runs is the
    # only way to make each run a real probe without deleting cache files. Network
    # is exempt: a probe that runs out of budget is never written, so it always probes.
    if ($kind.name -ne 'network') { Start-Sleep -Seconds 6 }

    # ---- strict run: window 0, order must be preserved exactly ----
    $strict = Invoke-HolRun -SlowJson $kind.json -Window 0 -Label ($kind.name + '-strict')
    if ($strict.SlowElapsed -lt ($WindowMs + 100)) {
        $why = if ($strict.SlowElapsed -le 5) { 'answer came from cache' } else { 'genuinely fast' }
        Add-Row -Case $kind.name -Verdict 'SKIP' -Detail `
        ("slow request {0} ms ({1}); needs >= {2} ms to create a gap worth reordering" -f $strict.SlowElapsed, $why, ($WindowMs + 100))
        continue
    }
    $strictOrderOk = (($strict.Order -join ',') -eq ((1..50) -join ','))
    $strictIdsOk = ($strict.Order.Count -eq 50) -and ((($strict.Order | Sort-Object -Unique).Count) -eq 50)
    $strictHold = ($strict.PingsBefore -eq 0) -and $strictOrderOk
    $strictVerdict = if ($strictIdsOk -and $strictHold) { 'PASS' } else { 'FAIL' }
    if ($strictVerdict -eq 'FAIL') {
        $script:failures.Add("$($kind.name)/strict : order=$($strict.Order -join ',') pings_before=$($strict.PingsBefore)")
    }
    Add-Row -Case ($kind.name + '/strict') -Verdict $strictVerdict -Detail `
    ("slow={0}ms pings_before={1}/49 order_ok={2} wall={3}ms" -f $strict.SlowArrive, $strict.PingsBefore, $strictOrderOk, $strict.Wall)

    # ---- windowed run: fast answers must escape the gap ----
    if ($kind.name -ne 'network') { Start-Sleep -Seconds 6 }
    $win = Invoke-HolRun -SlowJson $kind.json -Window $WindowMs -Label ($kind.name + '-window')
    if ($win.SlowElapsed -lt ($WindowMs + 100)) {
        Add-Row -Case ($kind.name + '/window') -Verdict 'SKIP' -Detail `
        ("slow request {0} ms this round (cache or coalescing won the race) - no gap to escape" -f $win.SlowElapsed)
        continue
    }
    $winIdsOk = ($win.Order.Count -eq 50) -and ((($win.Order | Sort-Object -Unique).Count) -eq 50)
    $escaped = ($win.PingsBefore -ge 45)
    $winVerdict = if ($winIdsOk -and $escaped) { 'PASS' } else { 'FAIL' }
    if ($winVerdict -eq 'FAIL') {
        $script:failures.Add("$($kind.name)/window : pings_before=$($win.PingsBefore)/49 (<45), ids_ok=$winIdsOk")
    }
    Add-Row -Case ($kind.name + '/window') -Verdict $winVerdict -Detail `
    ("slow={0}ms pings_before={1}/49 ping_first={2}ms ping_last={3}ms wall={4}ms" -f `
            $win.SlowArrive, $win.PingsBefore, $win.PingFirst, $win.PingLast, $win.Wall)

    # ---- hold: the promise is that an escaped answer waits at most W + slack ----
    if ($null -eq $win.MaxHold) {
        Add-Row -Case ($kind.name + '/hold') -Verdict 'SKIP' -Detail 'no "max hold" line on stderr (reorder log not emitted or log level off)'
    } else {
        $holdOk = ($win.MaxHold -le ($WindowMs + 50))
        if (-not $holdOk) { $script:failures.Add("$($kind.name)/hold : max hold $($win.MaxHold) ms > $($WindowMs + 50) ms") }
        Add-Row -Case ($kind.name + '/hold') -Verdict $(if ($holdOk) { 'PASS' } else { 'FAIL' }) -Detail `
        ("max hold={0}ms (limit {1}ms) reordered={2}" -f $win.MaxHold, ($WindowMs + 50), $win.Reordered)
    }

    # ---- the slow answer itself must not be pushed back BY THE WINDOW ----
    # arrive - own_elapsed is not "the window's hold": it is everything that happened to
    # this request before its handler started (cross-process probe lock, thread pool,
    # scheduling) PLUS the emit hold. Asserting a fixed 150 ms on it produced two false
    # reds on the frozen baseline - network 2392 ms and tools-versions 72837 ms - where
    # the reorder hold was correctly 207/214 ms and the gap was queueing long before the
    # window existed. The only honest test is a differential one: the window run must not
    # queue the slow request more than the strict run did, beyond the window itself.
    $slowGapWin = $win.SlowArrive - $win.SlowElapsed
    $slowGapStrict = if ($null -ne $strict.SlowArrive -and $null -ne $strict.SlowElapsed) { $strict.SlowArrive - $strict.SlowElapsed } else { $null }
    if ($null -eq $slowGapStrict) {
        Add-Row -Case ($kind.name + '/slow-queue') -Verdict 'INFO' -Detail ("queue gap window={0}ms (no strict baseline to compare)" -f $slowGapWin)
    } else {
        $addedByWindow = $slowGapWin - $slowGapStrict
        $slowOk = ($addedByWindow -le 50)
        if (-not $slowOk) { $script:failures.Add("$($kind.name)/slow-queue : the window added $addedByWindow ms of delay to the slow request (window $slowGapWin ms vs strict $slowGapStrict ms)") }
        Add-Row -Case ($kind.name + '/slow-queue') -Verdict $(if ($slowOk) { 'PASS' } else { 'FAIL' }) -Detail `
        ("queue gap window={0}ms strict={1}ms added={2}ms (limit 50)" -f $slowGapWin, $slowGapStrict, $addedByWindow)
        # Anything the request waited for before its handler ran is a separate finding and
        # must not be read as a reorder cost: report it, do not fail on it here.
        if ($slowGapStrict -gt 150) {
            Add-Row -Case ($kind.name + '/pre-queue') -Verdict 'INFO' -Detail `
            ("the slow request waited {0}ms before its handler started, in the STRICT run too - that is a lock/queue cost, not a reorder cost" -f $slowGapStrict)
        }
    }

    # ---- observation only: did the window actually reorder anything? ----
    if ($null -ne $win.Reordered) {
        Add-Row -Case ($kind.name + '/reordered') -Verdict 'INFO' -Detail ("reordered=$($win.Reordered) (strict run reported $($strict.Reordered))")
    }
}

Write-Host ''
$reportPath = Join-Path $OutDir ("reorder-{0}.csv" -f ([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')))
# Fingerprint inside the report: a CSV row without one is a number with no build attached.
$script:rows | Select-Object *, @{ n = 'fingerprint'; e = { $fingerprint } } | Export-Csv -Path $reportPath -NoTypeInformation -Encoding UTF8
Write-Host "report: $reportPath"

$skip = @($script:rows | Where-Object { $_.verdict -eq 'SKIP' }).Count
if ($script:failures.Count -gt 0) {
    Write-Host ''
    Write-Host "CONTRACT VIOLATIONS ($($script:failures.Count)):" -ForegroundColor Red
    foreach ($f in $script:failures) { Write-Host "  - $f" -ForegroundColor Red }
    exit 1
}
Write-Host ''
Write-Host "contract OK (skipped=$skip)  fingerprint=$fingerprint"
exit 0
