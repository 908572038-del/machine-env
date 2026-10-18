<#
.SYNOPSIS
    Concurrency burst harness for machine-env-cpp: latency, thread/handle/WS peaks
    and (once Phase 5 lands) real-probe counts per burst.

.DESCRIPTION
    Injects N JSON-RPC requests into ONE server process over stdin, timestamps every
    response line as it arrives, and samples the server process from a side runspace.

    Fixture (fixed on purpose, so numbers stay comparable across runs):
      * network probes: get_network with skip_endpoints=["__none__"] (bypasses cache,
        touches all 4 endpoints) and timeout_ms=1200. 1200 is a fixture value, NOT the
        default: the default is kNetworkBudgetMs = 2500, and 1200 is below it so a case
        finishes in ~1.2 s instead of ~2.5 s. Pinning it also fixes what arrival p99
        means, because every probe is capped by its own budget - which is why the burst
        p50 is flat (~1214 -> 1268 ms) all the way from K=1 to K=400.
      * K = 1 distinct attempt signature unless a case says otherwise.
      * cache is cold for network on this machine: a probe that exhausts its budget is
        never written to the on-disk cache, so every network case here is a real probe.

    Sampling: a side runspace polls Threads / HandleCount / WorkingSet64 of every
    machine-env-cpp process. Default interval -SampleIntervalMs 15 (see param help).
    The harness assumes one server instance at a time (true on a CI runner); with two
    instances the peak would be the max over both and is not attributable.

    Resource facts measured on this build - recorded, deliberately NOT written as PASS
    criteria, because these numbers moved ~22% between two builds of the same week and
    would date fast:
      * threads: a network burst does not come back to the idle level. The WinHTTP pool
        keeps the size it grew to (~182 threads / ~61 MB after 100 concurrent), while a
        ping burst does return (100 -> 4 threads in ~266 ms).
      * handles: growth is BOUNDED, not zero and not linear. Workers are reaped once
        they have finished (main.cpp kReapAfter = 32), so the same 100-ping rounds give
        184 / 284 / 384 / 484 / 584 handles per round on a build without the reaper and
        127 / 135 / 133 / 150 / 179 / 144 on the build with it (baseline 84).
        The criterion is:  handles_after <= handles_before + burst_size * 1.05, and not
        monotonic in the number of calls. A gapped caller sees ~+21 over 300 calls; a
        one-shot 100-line injection sees +45..95, because all three reap points (32,
        64, 96) pass before the workers have returned. Same conclusion either way, so
        assert the bound, never a fixed increment, and never "back to baseline" (see
        the next bullet for why that one can never pass).
      * there is a floor nobody can remove: the FIRST network probe on its own costs
        ~14 threads / ~+280 handles / ~+10 MB of WinHTTP pool. So on a process that has
        probed the network, "returned to the idle baseline" can never hold - write
        "returned to base + pool" instead.
      * a thread-creation wall was never reached: 40960 concurrent pings peak at 36830
        threads, answer all 40961, 0 errors, 3.2 GB. Forcing exhaustion with a 32 MB job
        object dies with 0xC00000FD STACK_OVERFLOW, which is uncatchable, so the `catch`
        around emplace_back is unreachable on this machine.
      * a cap on the probe layer is a RESOURCE measure, never a latency one. Arrival p50
        is flat from K=1 to K=400 (1214 / 1216 / 1232 / 1236 / 1268 ms) because each
        probe is bounded by its own budget and the endpoints are independent, so no cap
        at any level can shorten a burst. What a cap moves is threads and bytes only:
        K=400 peaks at 2393 threads / 368 MB. Never write "cap => lower p99"; the
        target that a cap can be held to is "peak threads <= model + slack", and against
        the 204-thread upper bound for N=100/cap=16 the measurement is 105 at K=16.
      * the thread model that fits the measurements is 5 + N + 14 + 4.2*max(0, K-1)
        (K = distinct attempt signatures actually probing). The ceiling used below,
        N + 4*min(K,cap) + 40, is a conservative upper bound of it: 204 vs ~182 at
        N=100/cap=16, 144 vs ~119 at N=100 fully deduped. Note cap only bounds the probe
        side - the N worker threads are not bounded by cap, so "cap=16 => ~110 threads"
        only holds at N~16. Peak working set at cap=16 is ~42 MB (N=100) or ~35 MB
        (N=16), not 20 MB: 20 MB was 16 x 1.22 where 1.22 is the *marginal* MB per
        probe at K=100 and ignores the ~10 MB fixed pool.

    Verdicts:
      PASS  contract holds (ids complete, latency inside its own budget, no crash)
      FAIL  contract violated -> exit code 1
      N/A   a Phase 5 target metric has no data source in this build (the field is not
            implemented yet). Printed as "N/A (<field> not implemented)", never as SKIP,
            and it forces exit code 2 so that "not measured" cannot be mistaken for
            "measured and fine". Pass -AllowIncomplete to downgrade that to exit 0 for
            exploratory runs.
      SKIP  precondition absent for a different reason (e.g. the machine did not reach
            the load the case needs, or a cached answer made the case meaningless)
      MEASURE  target metric recorded but not enforced (pre-Phase 5 baseline)

    Phase 5 targets (thread ceiling, handle ceiling, real-probe delta) are recorded
    as MEASURE by default. Pass -EnforcePhase5Targets to make them FAIL-able; flip
    that on only after dedupe + per-endpoint negative cache have landed. The
    real-probe delta needs a counter the diag line does not carry yet (attempts=), so
    it renders N/A and forces exit 2 until that field exists.

.PARAMETER AllowIncomplete
    Tolerate N/A rows (a target metric with no data source) and still exit 0. Without
    it the harness exits 2, because "not measured" must not share an exit code with
    "measured and fine" - that is what makes a nightly stay green forever.

.PARAMETER Cases
    Allowed: base, peak, bypass, plain, refresh, cheap, warm, cold-system.
    cold-system is NOT in the default list on purpose: it takes ~7 s and starts ~200
    pwsh trees, so it pollutes every cell scheduled after it in the same run. Run it on
    its own, and let whatever follows it start a fresh server process.

    Measurement rule: ONE FRESH SERVER PROCESS PER CELL. Not to avoid a handle leak
    (that is fixed - workers are reaped once finished), but because the same cell run
    twice inside one process differed by 35% (K=100: 527 / 711 / 493 peak threads), so
    any threshold would be inside the noise. Every Invoke-Burst call already spawns its
    own process; only cold-system's leading sleep runs outside it.

.PARAMETER SampleIntervalMs
    Side-sampler poll interval in milliseconds (default 15). 15 ms was chosen because
    the shortest real burst in this harness lasts ~1.2 s (about 80 samples) while a
    5 ms sampler started to perturb the very scheduler being measured.

.EXAMPLE
    powershell -NoProfile -File scripts/perf-burst-concurrency.ps1
    powershell -NoProfile -File scripts/perf-burst-concurrency.ps1 -Cases base,peak -EnforcePhase5Targets
#>
[CmdletBinding()]
param(
    [string]$ExePath = '',
    [int]$SampleIntervalMs = 15,
    [string[]]$Cases = @('base', 'peak', 'bypass', 'plain', 'refresh', 'cheap', 'warm'),
    [switch]$EnforcePhase5Targets,
    [switch]$AllowIncomplete,
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
$script:notImplemented = New-Object System.Collections.Generic.List[string]
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

# "powershell -File script.ps1 -Cases peak,base" passes the literal string "peak,base",
# which binds to [string[]] as ONE element, so split on commas here as well.
$Cases = @($Cases | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$knownCases = @('base', 'peak', 'bypass', 'plain', 'refresh', 'cheap', 'warm', 'cold-system')
foreach ($c in $Cases) {
    if ($knownCases -notcontains $c) { Write-Host "warning: unknown case '$c' (known: $($knownCases -join ', '))" -ForegroundColor Yellow }
}

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

$fingerprint = Get-ServerFingerprint -Exe $ExePath
$cores = [int]$env:NUMBER_OF_PROCESSORS
$stamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
Write-Host "== perf-burst-concurrency =="
Write-Host "exe          : $ExePath"
Write-Host "fingerprint  : $fingerprint"
Write-Host "cores        : $cores"
Write-Host "sampler      : ${SampleIntervalMs} ms (threads/handles/working set)"
Write-Host "fixture      : timeout_ms=1200 (leases to the 1500 tier), cold network cache, 4 endpoints"
Write-Host "paths        : base/peak = skip_endpoints (cache bypass, real probe) | bypass = refresh+skip"
Write-Host "               plain = plain cold call | refresh = refresh only (takes the cross-process lock)"
Write-Host "               cold-system = opt-in (add to -Cases), ~7 s, no latency contract yet"
Write-Host "started      : $stamp"
Write-Host "targets      : $(if ($EnforcePhase5Targets) { 'ENFORCED' } else { 'measure-only until Phase 5 lands' })"
Write-Host ''

$init = '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"perf-burst","version":"1"}}}'

function New-NetworkCalls {
    param([int]$Count, [switch]$Refresh, [switch]$Skip, [int]$IdBase = 0)
    # NB: PowerShell variable names are case-insensitive, so a local called $refresh
    # would *be* the [switch]$Refresh parameter and assigning a string to it fails.
    $parts = @()
    if ($Refresh) { $parts += '"refresh":true' }
    if ($Skip) { $parts += '"skip_endpoints":["__none__"]' }
    $parts += '"timeout_ms":1200'
    $parts += '"detail":false'
    $argJson = ($parts -join ',')
    for ($i = 1; $i -le $Count; $i++) {
        '{"jsonrpc":"2.0","id":' + ($IdBase + $i) + ',"method":"tools/call","params":{"name":"get_network","arguments":{' + $argJson + '}}}'
    }
}

function New-SystemCalls {
    param([int]$Count, [switch]$Refresh, [int]$IdBase = 0)
    $argJson = if ($Refresh) { '{"refresh":true,"detail":false}' } else { '{"detail":false}' }
    for ($i = 1; $i -le $Count; $i++) {
        '{"jsonrpc":"2.0","id":' + ($IdBase + $i) + ',"method":"tools/call","params":{"name":"get_system","arguments":' + $argJson + '}}'
    }
}

function New-SimpleCalls {
    param([int]$Count, [string]$Method, [string]$Name = '', [string]$Arguments = '{}')
    for ($i = 1; $i -le $Count; $i++) {
        if ($Method -eq 'ping') {
            '{"jsonrpc":"2.0","id":' + $i + ',"method":"ping"}'
        } else {
            '{"jsonrpc":"2.0","id":' + $i + ',"method":"tools/call","params":{"name":"' + $Name + '","arguments":' + $Arguments + '}}'
        }
    }
}

# A reading is an ordinary probe whose only purpose is to make the server report its
# attempt counters; it always probes, because a network result that ran out of budget
# is never cached. Two of them (before/after) bracket a burst and cancel each other out.
function New-ReadCall {
    param([int]$Id)
    '{"jsonrpc":"2.0","id":' + $Id + ',"method":"tools/call","params":{"name":"get_network","arguments":{"skip_endpoints":["__none__"],"timeout_ms":1200,"detail":false}}}'
}

function Invoke-Burst {
    param([string[]]$Requests, [string]$Label, [switch]$WithReadings, [switch]$WithDiag, [int]$SettleMs = 450)

    # With -WithReadings the stream is emitted in two phases with a real pause in
    # between, so the attempt counters can be read as "before" and "after" *inside
    # the same process* (the attempt cache never crosses processes: the on-disk cache
    # refuses a result that ran out of budget, machine.cpp:964-992). Ids 9001/9002
    # are the readings; they are excluded from the burst statistics.
    $phase1 = New-Object 'System.Collections.Generic.List[string]'
    $phase1.Add($init)
    if ($WithReadings) { $phase1.Add((New-ReadCall -Id 9001)) }
    foreach ($r in $Requests) { $phase1.Add($r) }
    $phase2 = New-Object 'System.Collections.Generic.List[string]'
    if ($WithReadings) { $phase2.Add((New-ReadCall -Id 9002)) }

    $sampleLog = Join-Path $OutDir ("samples-$Label.csv")
    $stopFile = Join-Path $OutDir ("stop-$Label.flag")
    Remove-Item $sampleLog, $stopFile -ErrorAction SilentlyContinue

    $sampler = [PowerShell]::Create()
    $null = $sampler.AddScript({
        param($interval, $stop, $log)
        $deadline = (Get-Date).AddMinutes(10)
        while (-not (Test-Path $stop) -and (Get-Date) -lt $deadline) {
            foreach ($p in @(Get-Process machine-env-cpp -ErrorAction SilentlyContinue)) {
                try {
                    Add-Content -Path $log -Value ("{0}`t{1}`t{2}`t{3}`t{4}" -f `
                        [DateTime]::UtcNow.ToString('HH:mm:ss.fff'), $p.Id, $p.Threads.Count,
                        $p.HandleCount, [math]::Round($p.WorkingSet64 / 1MB, 1))
                } catch { }
            }
            Start-Sleep -Milliseconds $interval
        }
    })
    $null = $sampler.AddParameter('interval', $SampleIntervalMs)
    $null = $sampler.AddParameter('stop', $stopFile)
    $null = $sampler.AddParameter('log', $sampleLog)
    $handle = $sampler.BeginInvoke()

    $sw = [Diagnostics.Stopwatch]::StartNew()
    [Console]::OutputEncoding = $script:utf8
    if ($WithReadings -or $WithDiag) { $env:MACHINE_ENV_DIAG = '1' }
    try {
        $raw = & {
            foreach ($l in $phase1) { $l }
            if ($WithReadings) { Start-Sleep -Milliseconds $SettleMs }
            foreach ($l in $phase2) { $l }
        } | & $ExePath 2>&1 | ForEach-Object {
            $t = $sw.ElapsedMilliseconds
            $text = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { [string]$_ }
            '{0}|{1}' -f $t, $text
        }
    } finally {
        $sw.Stop()
        if ($WithReadings -or $WithDiag) { Remove-Item Env:MACHINE_ENV_DIAG -ErrorAction SilentlyContinue }
        [Console]::OutputEncoding = $script:originalConsoleEncoding
    }

    Set-Content -Path $stopFile -Value 'stop'
    try { $null = $sampler.EndInvoke($handle) } catch { }
    $sampler.Dispose()

    $responses = New-Object System.Collections.Generic.List[object]
    $stderr = New-Object System.Collections.Generic.List[string]
    $diag = New-Object System.Collections.Generic.List[object]
    foreach ($line in $raw) {
        $cut = $line.IndexOf('|')
        if ($cut -lt 0) { continue }
        $arrive = [int]$line.Substring(0, $cut)
        $text = $line.Substring($cut + 1).Trim()
        if (-not $text.StartsWith('{')) {
            if ($text) { $stderr.Add($text) }
            # Per-response diag line, off unless MACHINE_ENV_DIAG=1. Shape as of this
            # build:  machine-env-cpp diag: seq=<n> tool=<name|-> wait_ms=<n> reordered=<0|1>
            # It is parsed as "seq plus a bag of key=value integers" rather than by field
            # order, because the shape already changed once and will again (attempts=,
            # inflight_peak=, max_hold_ms= are all expected to be added). A judgement for
            # a field that has not arrived yet stays SKIP; it never guesses.
            $dl = ConvertFrom-DiagLine -Text $text
            if ($dl) { $diag.Add($dl) }
            continue
        }
        # ASCII keys only: the payload carries UTF-8 summary text that may be
        # decoded lossily, but the numbers we assert on never are.
        $idMatch = [regex]::Match($text, '"id":(\d+)')
        if (-not $idMatch.Success) { $stderr.Add('no id: ' + $text.Substring(0, [Math]::Min(80, $text.Length))); continue }
        $id = [int]$idMatch.Groups[1].Value
        if ($id -le 0) { continue }
        $elapsedMatch = [regex]::Match($text, '"elapsed_ms":(\d+)')
        $attemptMatch = [regex]::Match($text, '"probe_attempts_started_total":(\d+)')
        $inflightMatch = [regex]::Match($text, '"probe_inflight_peak":(\d+)')
        # _cache.shared / _cache.hit are the PRIMARY evidence for "did this call really
        # probe": they ride on the answer, so a reviewer can count them later from the
        # saved JSON without re-running anything and without turning on a debug channel.
        # A counter in an opt-in diag line cannot do that, which is why the main
        # judgement must not hang off MACHINE_ENV_DIAG.
        $sharedMatch = [regex]::Match($text, '"shared":\s*(true|false)')
        $hitMatch = [regex]::Match($text, '"hit":\s*(true|false)')
        $reasonMatch = [regex]::Match($text, '"reason":"([^"]{0,40})"')
        $responses.Add([pscustomobject]@{
                id       = $id
                arrive   = $arrive
                elapsed  = $(if ($elapsedMatch.Success) { [double]$elapsedMatch.Groups[1].Value } else { [double]::NaN })
                attempts = $(if ($attemptMatch.Success) { [double]$attemptMatch.Groups[1].Value } else { [double]::NaN })
                inflight = $(if ($inflightMatch.Success) { [double]$inflightMatch.Groups[1].Value } else { [double]::NaN })
                shared   = $(if ($sharedMatch.Success) { $sharedMatch.Groups[1].Value -eq 'true' } else { $null })
                hitCache = $(if ($hitMatch.Success) { $hitMatch.Groups[1].Value -eq 'true' } else { $null })
                reason   = $(if ($reasonMatch.Success) { $reasonMatch.Groups[1].Value } else { '' })
                isError  = [bool]([regex]::IsMatch($text, '"error":\s*\{'))
            })
    }

    $peaks = [pscustomobject]@{ threads = 0; handles = 0; ws = 0.0; samples = 0 }
    if (Test-Path $sampleLog) {
        $sampleRows = @(Get-Content $sampleLog | ForEach-Object {
            $p = $_ -split "`t"
            if ($p.Count -ge 5) { [pscustomobject]@{ thr = [int]$p[2]; hnd = [int]$p[3]; ws = [double]$p[4] } }
        })
        if ($sampleRows.Count -gt 0) {
            $peaks = [pscustomobject]@{
                threads = ($sampleRows | Measure-Object thr -Maximum).Maximum
                handles = ($sampleRows | Measure-Object hnd -Maximum).Maximum
                ws      = ($sampleRows | Measure-Object ws -Maximum).Maximum
                samples = $sampleRows.Count
            }
        }
    }

    # Ordering cost, summarised here rather than in a helper: the helper took an
    # [object[]] copy of a List[object] and threw "parameter type mismatch" on the very
    # first frozen-baseline run, which then *looked* like "diag line absent". A silent
    # conversion failure that reads as a missing feature is the worst failure mode in a
    # harness, so the summary now happens where the data is produced.
    $waitVals = New-Object 'System.Collections.Generic.List[double]'
    $reorderCount = 0
    foreach ($e in $diag) {
        if ($null -ne $e.wait) { $waitVals.Add([double]$e.wait) }
        if ($null -ne $e.reordered -and $e.reordered -ge 1) { $reorderCount++ }
    }
    $waitP50 = $null
    $waitP99 = $null
    if ($waitVals.Count -gt 0) {
        $wa = $waitVals.ToArray()
        $waitP50 = Get-Quantile -Values $wa -Q 0.5
        $waitP99 = Get-Quantile -Values $wa -Q 0.99
    }

    [pscustomobject]@{
        Label      = $Label
        Wall       = $sw.ElapsedMilliseconds
        Responses  = $responses
        Stderr     = $stderr
        Diag       = $diag
        DiagCount  = $diag.Count
        WaitP50    = $waitP50
        WaitP99    = $waitP99
        Reordered  = $reorderCount
        # Counted straight off the answers: how many calls shared someone else's attempt,
        # how many were served from cache, and how many therefore had to probe. When
        # neither field is present the counts stay $null so a judgement can say N/A.
        SharedTrue = @($responses | Where-Object { $_.shared -eq $true }).Count
        HitTrue    = @($responses | Where-Object { $_.hitCache -eq $true }).Count
        CacheKnown = @($responses | Where-Object { $null -ne $_.shared -or $null -ne $_.hitCache }).Count
        Peaks      = $peaks
        Expected   = $Requests.Count
    }
}

# Tolerant parser for the per-response stderr diag line. It is deliberately not a fixed
# field-order regex: the line already differs from the version this harness was written
# against, and attempts= / inflight_peak= / max_hold_ms= are expected to be added later.
# Anything shaped key=<integer> lands in .fields; .seq and .wait are the two that are
# required for a line to count at all.
function ConvertFrom-DiagLine {
    param([string]$Text)
    if ($Text -notmatch 'diag:?\s*seq=(\d+)') { return $null }
    $fields = @{}
    foreach ($m in [regex]::Matches($Text, '([a-z_]+)=(-?\d+)')) {
        $fields[$m.Groups[1].Value] = [double]$m.Groups[2].Value
    }
    [pscustomobject]@{
        seq       = [int]$fields['seq']
        wait      = $fields['wait_ms']
        reordered = $fields['reordered']
        fields    = $fields
    }
}

# Ordering cost lives on the burst object now (see Invoke-Burst): wait_ms is how long a
# finished answer stood in the reorder buffer before it was written, so its p99 is the
# price the order promise charged this burst. A burst with no slow request ahead of it
# reads ~0; one waiting out the window reads ~W.

function Get-Quantile {
    param([double[]]$Values, [double]$Q)
    $v = @($Values | Sort-Object)
    if ($v.Count -eq 0) { return [double]::NaN }
    $idx = [int][math]::Floor(($v.Count - 1) * $Q)
    return $v[$idx]
}

function Add-Row {
    param([string]$Case, [string]$Verdict, [string]$Detail)
    $script:rows.Add([pscustomobject]@{ case = $Case; verdict = $Verdict; detail = $Detail })
    if ($Verdict -eq 'N/A') { $script:notImplemented.Add("$Case : $Detail") }
    Write-Host ("{0,-26} {1,-8} {2}" -f $Case, $Verdict, $Detail)
}

function Assert-Contract {
    param([bool]$Ok, [string]$Case, [string]$Message)
    if (-not $Ok) { $script:failures.Add("$Case : $Message") }
    return $Ok
}

# ---------------------------------------------------------------------------
# Case base: one call per N: ceiling for latency, and the resource curve knee
# ---------------------------------------------------------------------------
if ($Cases -contains 'base') {
    foreach ($n in 1, 8, 16, 100) {
        $b = Invoke-Burst -Requests (New-NetworkCalls -Count $n -Skip) -Label "base-n$n"
        $arrive = @($b.Responses | ForEach-Object { $_.arrive })
        $elapsed = @($b.Responses | ForEach-Object { $_.elapsed })
        $ids = @($b.Responses | ForEach-Object { $_.id })
        $complete = ($ids.Count -eq $n) -and ((($ids | Sort-Object -Unique).Count) -eq $n)
        $ok = Assert-Contract -Ok $complete -Case "base-n$n" -Message "expected $n distinct ids, got $($ids.Count)"
        $p99 = Get-Quantile -Values $arrive -Q 0.99
        $inner = if ($elapsed.Count) { ($elapsed | Measure-Object -Maximum).Maximum } else { [double]::NaN }
        $budgetOk = Assert-Contract -Ok ($p99 -le 1350) -Case "base-n$n" -Message "p99 arrival $p99 ms exceeds budget 1200+150"
        $detail = ("wall={0}ms p99={1}ms inner_max={2}ms thr={3} hnd={4} ws={5}MB samples={6}" -f `
                $b.Wall, $p99, $inner, $b.Peaks.threads, $b.Peaks.handles, $b.Peaks.ws, $b.Peaks.samples)
        Add-Row -Case "base-n$n" -Verdict $(if ($ok -and $budgetOk) { 'PASS' } else { 'FAIL' }) -Detail $detail

        # Phase 5 target: threads <= N + 4*min(K,cap) + 40, K=1 here.
        $ceiling = $n + 4 * 1 + 40
        if ($b.Peaks.threads -gt $ceiling) {
            if ($EnforcePhase5Targets) {
                $script:failures.Add("base-n$n : peak threads $($b.Peaks.threads) > ceiling $ceiling")
                Add-Row -Case "base-n$n/thr" -Verdict 'FAIL' -Detail "peak threads $($b.Peaks.threads) > ceiling $ceiling (N+4*min(K,cap)+40)"
            } else {
                Add-Row -Case "base-n$n/thr" -Verdict 'MEASURE' -Detail "peak threads $($b.Peaks.threads) > Phase5 ceiling $ceiling (expected pre-dedupe)"
            }
        } else {
            Add-Row -Case "base-n$n/thr" -Verdict 'PASS' -Detail "peak threads $($b.Peaks.threads) <= ceiling $ceiling"
        }
    }
}

# ---------------------------------------------------------------------------
# Case peak: N=300. Not a latency test (service time is flat with concurrency);
# it exists to show how far resources scale per request.
# ---------------------------------------------------------------------------
if ($Cases -contains 'peak') {
    $n = 300
    $b = Invoke-Burst -Requests (New-NetworkCalls -Count $n -Skip) -Label 'peak-n300'
    $ids = @($b.Responses | ForEach-Object { $_.id })
    $complete = ($ids.Count -eq $n) -and ((($ids | Sort-Object -Unique).Count) -eq $n)
    $p99 = Get-Quantile -Values @($b.Responses | ForEach-Object { $_.arrive }) -Q 0.99
    # N=300 is not a shipping concurrency target; this case exists to show the
    # scaling law (threads/handles/WS per request), and at ~1500 live threads the
    # arrival p99 is dominated by scheduler contention rather than by the probe.
    # The latency tolerance is therefore wider here on purpose - the contract number
    # that matters is the <=100 case above.
    $tolerance = 300
    $ok = Assert-Contract -Ok $complete -Case 'peak-n300' -Message "expected $n distinct ids, got $($ids.Count)"
    $budgetOk = Assert-Contract -Ok ($p99 -le (1200 + $tolerance)) -Case 'peak-n300' -Message "p99 arrival $p99 ms exceeds budget+$tolerance"
    Add-Row -Case 'peak-n300' -Verdict $(if ($ok -and $budgetOk) { 'PASS' } else { 'FAIL' }) -Detail `
    ("wall={0}ms p99={1}ms thr={2} hnd={3} ws={4}MB" -f $b.Wall, $p99, $b.Peaks.threads, $b.Peaks.handles, $b.Peaks.ws)
    $ceiling = $n + 4 * 1 + 40
    if ($b.Peaks.threads -gt $ceiling) {
        if ($EnforcePhase5Targets) {
            $script:failures.Add("peak-n300 : peak threads $($b.Peaks.threads) > ceiling $ceiling")
            Add-Row -Case 'peak-n300/thr' -Verdict 'FAIL' -Detail "peak threads $($b.Peaks.threads) > ceiling $ceiling"
        } else {
            Add-Row -Case 'peak-n300/thr' -Verdict 'MEASURE' -Detail "peak threads $($b.Peaks.threads) > Phase5 ceiling $ceiling"
        }
    } else {
        Add-Row -Case 'peak-n300/thr' -Verdict 'PASS' -Detail "peak threads $($b.Peaks.threads) <= ceiling $ceiling"
    }
}

# ---------------------------------------------------------------------------
# Case bypass: refresh=true *and* skip_endpoints. Non-empty skip_endpoints makes
# dispatch call probe_network directly (main.cpp:1189-1190), so this never touches
# the cache lock: it is the pure "N requests = N probes, all in parallel" shape.
# `refresh` is inert on this path - dispatch bypasses before refresh is consulted -
# so the row is really "skip_endpoints + timeout_ms only". It is carried here because
# an earlier iteration used refresh+skip to force a real probe, and dropping it now
# would silently make old and new CSVs incomparable.
# timeout_ms DOES apply even here: budget_ms is passed straight into probe_network.
# ---------------------------------------------------------------------------
if ($Cases -contains 'bypass') {
    $b = Invoke-Burst -Requests (New-NetworkCalls -Count 100 -Refresh -Skip) -Label 'bypass-n100'
    $p99 = Get-Quantile -Values @($b.Responses | ForEach-Object { $_.arrive }) -Q 0.99
    $ok = Assert-Contract -Ok ($b.Responses.Count -eq 100) -Case 'bypass-n100' -Message "expected 100 responses, got $($b.Responses.Count)"
    $fast = Assert-Contract -Ok ($p99 -le 1350) -Case 'bypass-n100' -Message "p99 $p99 ms exceeds budget+150"
    Add-Row -Case 'bypass-n100' -Verdict $(if ($ok -and $fast) { 'PASS' } else { 'FAIL' }) -Detail `
    ("wall={0}ms p99={1}ms thr={2} hnd={3} ws={4}MB" -f $b.Wall, $p99, $b.Peaks.threads, $b.Peaks.handles, $b.Peaks.ws)
    $ceiling = 100 + 4 * 1 + 40
    if ($b.Peaks.threads -gt $ceiling) {
        Add-Row -Case 'bypass-n100/thr' -Verdict $(if ($EnforcePhase5Targets) { 'FAIL' } else { 'MEASURE' }) -Detail `
            "peak threads $($b.Peaks.threads) > ceiling $ceiling (expected pre-dedupe: N parallel probes x 4 endpoints)"
        if ($EnforcePhase5Targets) { $script:failures.Add("bypass-n100 : peak threads $($b.Peaks.threads) > $ceiling") }
    } else {
        Add-Row -Case 'bypass-n100/thr' -Verdict 'PASS' -Detail "peak threads $($b.Peaks.threads) <= ceiling $ceiling"
    }
}

# ---------------------------------------------------------------------------
# Case plain: no refresh, no skip. This is the cold-cache path through
# cached_probe (machine.cpp:2244-2266): read, miss, probe - no lock, no dedupe.
# On this machine a network result is never written to disk (a probe that runs out
# of budget is not cached), so this path is always a cold miss.
# ---------------------------------------------------------------------------
if ($Cases -contains 'plain') {
    $b = Invoke-Burst -Requests (New-NetworkCalls -Count 100) -Label 'plain-n100' -WithDiag
    $p99 = Get-Quantile -Values @($b.Responses | ForEach-Object { $_.arrive }) -Q 0.99
    $ok = Assert-Contract -Ok ($b.Responses.Count -eq 100) -Case 'plain-n100' -Message "expected 100 responses, got $($b.Responses.Count)"
    $fast = Assert-Contract -Ok ($p99 -le 1350) -Case 'plain-n100' -Message "p99 $p99 ms exceeds budget+150"
    $p50 = Get-Quantile -Values @($b.Responses | ForEach-Object { $_.arrive }) -Q 0.5
    Add-Row -Case 'plain-n100' -Verdict $(if ($ok -and $fast) { 'PASS' } else { 'FAIL' }) -Detail `
    ("wall={0}ms p50={1}ms p99={2}ms thr={3} hnd={4} ws={5}MB" -f $b.Wall, $p50, $p99, $b.Peaks.threads, $b.Peaks.handles, $b.Peaks.ws)
    # The control for refresh-n100/wait: same 100 concurrent calls, no refresh, so nothing
    # slow sits ahead of anything and the ordering cost should be ~0. The gap between the
    # two wait_ms p99 values is the price of the reorder window on this shape.
    if ($b.DiagCount -ge 2 -and $null -ne $b.WaitP99) {
        Add-Row -Case 'plain-n100/wait' -Verdict 'INFO' -Detail ("ordering cost wait_ms p50={0} p99={1}, reordered={2}/{3}" -f $b.WaitP50, $b.WaitP99, $b.Reordered, $b.DiagCount)
    } else {
        Add-Row -Case 'plain-n100/wait' -Verdict 'N/A' -Detail ("N/A (wait_ms= absent or no diag lines, diag lines={0})" -f $b.DiagCount)
    }
    $ceiling = 100 + 4 * 1 + 40
    if ($b.Peaks.threads -gt $ceiling) {
        Add-Row -Case 'plain-n100/thr' -Verdict $(if ($EnforcePhase5Targets) { 'FAIL' } else { 'MEASURE' }) -Detail `
            "peak threads $($b.Peaks.threads) > ceiling $ceiling (expected pre-dedupe)"
        if ($EnforcePhase5Targets) { $script:failures.Add("plain-n100 : peak threads $($b.Peaks.threads) > $ceiling") }
    } else {
        Add-Row -Case 'plain-n100/thr' -Verdict 'PASS' -Detail "peak threads $($b.Peaks.threads) <= ceiling $ceiling"
    }
}

# ---------------------------------------------------------------------------
# Case cheap: the paths that must not regress. 60 ms is loose enough for a
# loaded runner and tight enough to catch a lock creeping back onto the read path.
# ---------------------------------------------------------------------------
if ($Cases -contains 'cheap') {
    $warm = Invoke-Burst -Requests (New-SimpleCalls -Count 1 -Method 'call' -Name 'get_system') -Label 'cheap-warm'
    foreach ($case in @(
            @{ name = 'ping'; calls = (New-SimpleCalls -Count 100 -Method 'ping') },
            @{ name = 'system-cached'; calls = (New-SimpleCalls -Count 100 -Method 'call' -Name 'get_system') }
        )) {
        $b = Invoke-Burst -Requests $case.calls -Label ("cheap-" + $case.name)
        $p99 = Get-Quantile -Values @($b.Responses | ForEach-Object { $_.arrive }) -Q 0.99
        $ok = Assert-Contract -Ok ($b.Responses.Count -eq 100) -Case ("cheap-" + $case.name) -Message "expected 100 responses, got $($b.Responses.Count)"
        $fast = Assert-Contract -Ok ($p99 -le 60) -Case ("cheap-" + $case.name) -Message "p99 $p99 ms exceeds 60 ms"
        Add-Row -Case ("cheap-" + $case.name) -Verdict $(if ($ok -and $fast) { 'PASS' } else { 'FAIL' }) -Detail `
        ("wall={0}ms p99={1}ms thr={2} hnd={3}" -f $b.Wall, $p99, $b.Peaks.threads, $b.Peaks.handles)
    }
}

# ---------------------------------------------------------------------------
# Case refresh: 100 concurrent refresh=true. This is the case that shows the
# 3000 ms degraded wait turning into a second stampede at t=3 s.
# Pre-Phase-5 it measures ~4.2 s and ~510 threads; after dedupe the targets are
# p50 <= 1350 ms, attempts delta <= 2, and no second thread lift.
# ---------------------------------------------------------------------------
if ($Cases -contains 'refresh') {
    # Two extra probes (ids 9001/9002) bracket the burst so the attempt counter can be
    # read before and after *inside one process* (the counter and the attempt cache are
    # per-process; a reading taken in another process would measure nothing). The settle
    # between them and the burst is >= W + 250 ms so the closing reading is not taken
    # from inside the burst. Both readings are excluded from every latency figure below,
    # and they inflate the stopwatch by the settle, so the wall reported here is "ms
    # until the last burst response arrived", not the process lifetime.
    $b = Invoke-Burst -Requests (New-NetworkCalls -Count 100 -Refresh) -Label 'refresh-n100' -WithReadings
    $burst = @($b.Responses | Where-Object { $_.id -lt 9000 })
    $burstWall = if ($burst.Count) { ($burst | Measure-Object arrive -Maximum).Maximum } else { $b.Wall }
    $p50 = Get-Quantile -Values @($burst | ForEach-Object { $_.arrive }) -Q 0.5
    $p99 = Get-Quantile -Values @($burst | ForEach-Object { $_.arrive }) -Q 0.99
    $ids = @($burst | ForEach-Object { $_.id })
    $ok = Assert-Contract -Ok (($ids.Count -eq 100) -and ((($ids | Sort-Object -Unique).Count) -eq 100)) -Case 'refresh-n100' -Message "expected 100 distinct ids, got $($ids.Count)"
    $stderrHit = ($b.Stderr -join "`n")
    Add-Row -Case 'refresh-n100' -Verdict $(if ($ok) { 'PASS' } else { 'FAIL' }) -Detail `
    ("burst={0}ms proc={1}ms p50={2}ms p99={3}ms thr={4} hnd={5} ws={6}MB" -f $burstWall, $b.Wall, $p50, $p99, $b.Peaks.threads, $b.Peaks.handles, $b.Peaks.ws)

    if ($b.DiagCount -lt 2) {
        Add-Row -Case 'refresh-n100/diag' -Verdict 'N/A' -Detail 'stderr diag line absent (N/A: MACHINE_ENV_DIAG=1 not honoured by this build)'
    } else {
        # Ordering cost. This is the number that makes the case arguable: on the frozen
        # build 99 of 101 responses pay wait_ms ~202-213 ms although their answers were
        # ready at once - they are held only to fill a hole ahead of them. The bound is
        # the window itself plus slack; it should drift towards 0 once the burst
        # collapses into one attempt and nothing slow is left ahead.
        if ($null -ne $b.WaitP99) {
            $waitOk = $b.WaitP99 -le 250
            Add-Row -Case 'refresh-n100/wait' -Verdict $(if ($waitOk) { 'PASS' } else { 'MEASURE' }) -Detail `
                ("ordering cost wait_ms p50={0} p99={1} (limit 250 = W+50), reordered={2}/{3}" -f $b.WaitP50, $b.WaitP99, $b.Reordered, $b.DiagCount)
            if (-not $waitOk -and $EnforcePhase5Targets) { $script:failures.Add("refresh-n100 : wait_ms p99 $($b.WaitP99) > 250") }
        } else {
            Add-Row -Case 'refresh-n100/wait' -Verdict 'N/A' -Detail 'N/A (wait_ms= absent from the diag line)'
        }

        # PRIMARY: count the answers, do not difference a counter. A cold 100-way refresh
        # burst with attempt sharing reads shared==true ~99 times (one owner probes, the
        # rest ride it); the shape without it reads shared==false everywhere and every
        # waiter probes once its patience runs out. Both are countable from the saved
        # JSON, without MACHINE_ENV_DIAG and without re-running anything - which a
        # counter in an opt-in debug line can never offer.
        if ($b.CacheKnown -lt 100) {
            Add-Row -Case 'refresh-n100/shared' -Verdict 'N/A' -Detail ("N/A (_cache.shared / _cache.hit not implemented: only {0}/100 answers carried either field)" -f $b.CacheKnown)
        } else {
            $sharedOk = ($b.SharedTrue -ge 99)
            if (-not $sharedOk -and $EnforcePhase5Targets) { $script:failures.Add("refresh-n100 : shared==true count $($b.SharedTrue)/100 < 99") }
            $sharedVerdict = if ($sharedOk) { 'PASS' } elseif ($EnforcePhase5Targets) { 'FAIL' } else { 'MEASURE' }
            Add-Row -Case 'refresh-n100/shared' -Verdict $sharedVerdict -Detail `
                ("shared==true {0}/100 (target >=99), cache hit {1}/100" -f $b.SharedTrue, $b.HitTrue)
        }

        # AUXILIARY: process-wide counters. They cannot prove a per-response fact and they
        # only exist behind MACHINE_ENV_DIAG, so they are a cross-check on the count above,
        # never the judgement itself.
        $ds = @($b.Diag | Sort-Object seq)
        $firstLine = $ds[0]
        $lastLine = $ds[$ds.Count - 1]
        $hasAttempts = ($null -ne $firstLine.fields['attempts']) -and ($null -ne $lastLine.fields['attempts'])
        if (-not $hasAttempts) {
            Add-Row -Case 'refresh-n100/attempts(aux)' -Verdict 'N/A' -Detail 'N/A (attempts= not implemented in the diag line) - auxiliary cross-check only; the judgement is refresh-n100/shared above'
        } else {
            # A fully coalesced burst reads 1, not 0: the closing reading is itself a probe.
            $delta = $lastLine.fields['attempts'] - $firstLine.fields['attempts']
            if ($delta -le 2) {
                Add-Row -Case 'refresh-n100/attempts(aux)' -Verdict 'PASS' -Detail ("attempts delta {0} <= 2 (expected 1: the closing reading probes too), diag lines={1}" -f $delta, $b.DiagCount)
            } elseif ($EnforcePhase5Targets) {
                $script:failures.Add("refresh-n100 : attempts delta $delta > 2")
                Add-Row -Case 'refresh-n100/attempts(aux)' -Verdict 'FAIL' -Detail "attempts delta $delta > 2 (stampede)"
            } else {
                Add-Row -Case 'refresh-n100/attempts(aux)' -Verdict 'MEASURE' -Detail "attempts delta $delta (pre-dedupe baseline)"
            }
            # Same lines, second cross-check: in-flight work must not scale with N.
            $bIn = $firstLine.fields['inflight_peak']; $eIn = $lastLine.fields['inflight_peak']
            if ($null -ne $bIn -and $null -ne $eIn) {
                $liftInflight = $eIn - $bIn
                $inflightVerdict = if ($liftInflight -le 3) { 'PASS' } elseif ($EnforcePhase5Targets) { 'FAIL' } else { 'MEASURE' }
                Add-Row -Case 'refresh-n100/inflight' -Verdict $inflightVerdict -Detail ("inflight_peak={0} (before={1}, lift={2}, limit 3)" -f $eIn, $bIn, $liftInflight)
                if ($EnforcePhase5Targets -and $liftInflight -gt 3) { $script:failures.Add("refresh-n100 : inflight_peak lift $liftInflight > 3") }
            } else {
                Add-Row -Case 'refresh-n100/inflight' -Verdict 'N/A' -Detail 'N/A (inflight_peak= not implemented)'
            }
        }
    }

    $lift = $b.Peaks.threads
    $ceiling = 100 + 4 * 1 + 40
    if ($lift -gt $ceiling) {
        Add-Row -Case 'refresh-n100/thr' -Verdict $(if ($EnforcePhase5Targets) { 'FAIL' } else { 'MEASURE' }) -Detail `
            "peak threads $lift > ceiling $ceiling (second lift at t~3s)"
        if ($EnforcePhase5Targets) { $script:failures.Add("refresh-n100 : peak threads $lift > $ceiling") }
    } else {
        Add-Row -Case 'refresh-n100/thr' -Verdict 'PASS' -Detail "peak threads $lift <= ceiling $ceiling"
    }
    if ($stderrHit -match 'emitted past a gap') { Add-Row -Case 'refresh-n100/stderr' -Verdict 'INFO' -Detail 'reorder window fired during this case' }
}

# ---------------------------------------------------------------------------
# Case warm: round 2 right after round 1, SAME process (the attempt cache is
# per-process only - nothing about it can be observed from another process).
# Three readings: before round 1 (9001), between the rounds (9002), after round 2
# (9003), each separated by a >= W + 250 ms settle. Round 2 uses ids 101..200 so its
# arrivals can be timed apart from round 1. Expected: round 1 costs 1 attempt-set,
# round 2 costs 0 (served from the attempt cache).
#
# That expectation holds per TOOL, and this case uses get_network, which is the one tool
# where it does not hold yet: a network probe that runs out of budget is never written
# to the on-disk cache, so after round 1 there is nothing for round 2 to hit. Two
# different fixes are needed and they are not the same fix -
#   * ③ attempt-level single flight  -> a caller can join an attempt already in flight;
#   * ① short-TTL attempt cache      -> a caller can hit an attempt that already finished.
# Round 2 of this case starts after both rounds are over, so it needs ①, not ③. Until ①
# lands, round 2 legitimately reads delta 1 and must not be recorded as a regression.
# With get_system instead of get_network, delta 0 holds today, because that payload does
# reach the cache.
# ---------------------------------------------------------------------------
if ($Cases -contains 'warm') {
    $round1 = New-NetworkCalls -Count 100
    $round2 = New-NetworkCalls -Count 100 -IdBase 100
    $sw = [Diagnostics.Stopwatch]::StartNew()
    [Console]::OutputEncoding = $script:utf8
    $env:MACHINE_ENV_DIAG = '1'
    try {
        $raw = & {
            $init
            New-ReadCall -Id 9001
            foreach ($r in $round1) { $r }
            Start-Sleep -Milliseconds 450
            New-ReadCall -Id 9002
            foreach ($r in $round2) { $r }
            Start-Sleep -Milliseconds 450
            New-ReadCall -Id 9003
        } | & $ExePath 2>&1 | ForEach-Object {
            $t = $sw.ElapsedMilliseconds
            $text = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { [string]$_ }
            '{0}|{1}' -f $t, $text
        }
    } finally {
        $sw.Stop()
        Remove-Item Env:MACHINE_ENV_DIAG -ErrorAction SilentlyContinue
        [Console]::OutputEncoding = $script:originalConsoleEncoding
    }

    $diag = New-Object 'System.Collections.Generic.List[object]'
    $round2Arrive = @()
    $r1seen = 0
    $r2seen = 0
    $r2Hit = 0
    $r2CacheKnown = 0
    foreach ($line in $raw) {
        $cut = $line.IndexOf('|'); if ($cut -lt 0) { continue }
        $arrive = [int]$line.Substring(0, $cut)
        $text = $line.Substring($cut + 1).Trim()
        if (-not $text.StartsWith('{')) {
            $dl = ConvertFrom-DiagLine -Text $text
            if ($dl) { $diag.Add($dl) }
            continue
        }
        $idMatch = [regex]::Match($text, '"id":(\d+)')
        if (-not $idMatch.Success) { continue }
        $id = [int]$idMatch.Groups[1].Value
        if ($id -gt 100 -and $id -lt 9000) {
            $round2Arrive += $arrive; $r2seen++
            # Round 2 must be served from what round 1 already produced, so every answer
            # should carry _cache.hit=true. That is a per-answer fact readable later from
            # the saved JSON, unlike a counter in an opt-in diag line.
            $hitM = [regex]::Match($text, '"hit":\s*(true|false)')
            if ($hitM.Success) { $r2CacheKnown++; if ($hitM.Groups[1].Value -eq 'true') { $r2Hit++ } }
        }
        elseif ($id -ge 1 -and $id -le 100) { $r1seen++ }
    }

    # Locate the three readings by seq. seq is the message index, so with the stream
    # above they sit at 1 / 2+100 / 3+200 - but only if the index is 0-based; try both
    # offsets instead of assuming, and SKIP rather than guess if neither lines up.
    $byS = @{}
    foreach ($e in $diag) { $byS[$e.seq] = $e }
    $pick = $null
    foreach ($off in 0, 1) {
        $sb = 1 + $off; $sm = 2 + $round1.Count + $off; $se = 3 + $round1.Count + $round2.Count + $off
        if ($byS.ContainsKey($sb) -and $byS.ContainsKey($sm) -and $byS.ContainsKey($se)) {
            $pick = [pscustomobject]@{ B = $byS[$sb]; M = $byS[$sm]; E = $byS[$se] }; break
        }
    }

    if ($r1seen -ne 100 -or $r2seen -ne 100) {
        Assert-Contract -Ok $false -Case 'warm-r2' -Message "expected 100+100 responses, got $r1seen+$r2seen" | Out-Null
        Add-Row -Case 'warm-r2' -Verdict 'FAIL' -Detail "responses $r1seen+$r2seen, expected 100+100"
    } else {
        # PRIMARY: round 2 must not probe at all, so count the answers.
        if ($r2CacheKnown -lt 100) {
            Add-Row -Case 'warm-r2/cached' -Verdict 'N/A' -Detail ("N/A (_cache.hit not implemented: only {0}/100 round-2 answers carried it)" -f $r2CacheKnown)
        } else {
            $hitOk = ($r2Hit -ge 99)
            if (-not $hitOk -and $EnforcePhase5Targets) { $script:failures.Add("warm-r2 : _cache.hit count $r2Hit/100 < 99") }
            $hitVerdict = if ($hitOk) { 'PASS' } elseif ($EnforcePhase5Targets) { 'FAIL' } else { 'MEASURE' }
            Add-Row -Case 'warm-r2/cached' -Verdict $hitVerdict -Detail ("_cache.hit true {0}/100 in round 2 (target >=99 = no new probe)" -f $r2Hit)
        }
    }
    if ($r1seen -ne 100 -or $r2seen -ne 100) { } elseif (-not $pick) {
        Add-Row -Case 'warm-r2' -Verdict 'N/A' -Detail ("N/A (diag seq layout or attempts= not readable; diag lines={0})" -f $diag.Count)
    } else {
        $attB = $pick.B.fields['attempts']; $attM = $pick.M.fields['attempts']; $attE = $pick.E.fields['attempts']
        $p50 = Get-Quantile -Values $round2Arrive -Q 0.5
        if ($null -eq $attB -or $null -eq $attM -or $null -eq $attE) {
            Add-Row -Case 'warm-r2' -Verdict 'N/A' -Detail ("N/A (attempts= not implemented; diag lines found={0}), round2 p50={1}ms" -f $diag.Count, $p50)
        } else {
            $r1delta = $attM - $attB
            $r2delta = $attE - $attM
            Add-Row -Case 'warm-r1/attempts' -Verdict 'INFO' -Detail ("round1 costs {0} attempt(s), p50 of round2 {1}ms" -f $r1delta, $p50)
            # 0 is the target; 1-2 is tolerated because the closing reading (9003) may itself
            # attempt, and the two extra readings cannot be attributed away from round 2.
            if ($r2delta -le 0) {
                Add-Row -Case 'warm-r2' -Verdict 'PASS' -Detail ("round2 attempts delta {0}, p50 {1}ms (attempt cache hit, no new probe)" -f $r2delta, $p50)
            } elseif ($r2delta -le 2) {
                Add-Row -Case 'warm-r2' -Verdict 'MEASURE' -Detail ("round2 attempts delta {0}, p50 {1}ms (tolerated: the closing reading may probe)" -f $r2delta, $p50)
            } elseif ($EnforcePhase5Targets) {
                $script:failures.Add("warm-r2 : attempts delta $r2delta, expected 0 inside the TTL")
                Add-Row -Case 'warm-r2' -Verdict 'FAIL' -Detail ("round2 attempts delta {0} > 2 (budget tier key mismatch?)" -f $r2delta)
            } else {
                Add-Row -Case 'warm-r2' -Verdict 'MEASURE' -Detail ("round2 attempts delta {0}, p50 {1}ms" -f $r2delta, $p50)
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Case cold-system (opt-in, ~7 s): 100 concurrent get_system refresh=true. Not in the
# default case list because it is slow and it perturbs everything after it (200 pwsh
# processes). It exists because an independent driver measured 7173 ms wall /
# 6947 ms p50 / 408 threads here - roughly 6x the single-request cost - which is the
# worst amplification found anywhere in this tool set. No latency contract yet: the
# row is MEASURE until probe fan-out is capped. The 6 s sleep crosses the refresh
# minimum-interval gate *outside* the process, otherwise every request is answered from
# cache and the case measures nothing (it would look like a 15 ms SKIP).
# Run it on its own: whatever cell follows it must start a fresh process, otherwise the
# ~200 pwsh trees it just spawned are the next cell's noise floor.
# ---------------------------------------------------------------------------
if ($Cases -contains 'cold-system') {
    $n = 100
    Start-Sleep -Seconds 6
    $b = Invoke-Burst -Requests (New-SystemCalls -Count $n -Refresh) -Label "cold-system-n$n"
    $arrive = @($b.Responses | ForEach-Object { $_.arrive })
    $p50 = Get-Quantile -Values $arrive -Q 0.5
    $p99 = Get-Quantile -Values $arrive -Q 0.99
    $ok = Assert-Contract -Ok ($b.Responses.Count -eq $n) -Case "cold-system-n$n" -Message "expected $n responses, got $($b.Responses.Count)"
    Add-Row -Case "cold-system-n$n" -Verdict $(if ($ok) { 'PASS' } else { 'FAIL' }) -Detail `
    ("wall={0}ms p50={1}ms p99={2}ms thr={3} hnd={4} ws={5}MB" -f $b.Wall, $p50, $p99, $b.Peaks.threads, $b.Peaks.handles, $b.Peaks.ws)
    Add-Row -Case "cold-system-n$n/lat" -Verdict 'MEASURE' -Detail ("p50={0}ms vs single-request ~1200ms (6x amplification expected pre-cap, no contract yet)" -f $p50)
}

Write-Host ''
$reportPath = Join-Path $OutDir ("burst-{0}.csv" -f ([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')))
# The fingerprint goes INTO the report, not just onto the console: a CSV without one is a
# number with no build attached, and this session alone produced seven fingerprints in
# under twenty minutes. Rows written before this line existed are unverifiable - if one
# of them is quoted later, treat it as unmeasured.
$script:rows | Select-Object *, @{ n = 'fingerprint'; e = { $fingerprint } } | Export-Csv -Path $reportPath -NoTypeInformation -Encoding UTF8
Write-Host "report: $reportPath"

$skip = @($script:rows | Where-Object { $_.verdict -eq 'SKIP' }).Count
$measure = @($script:rows | Where-Object { $_.verdict -eq 'MEASURE' }).Count
if ($script:failures.Count -gt 0) {
    Write-Host ''
    Write-Host "CONTRACT VIOLATIONS ($($script:failures.Count)):" -ForegroundColor Red
    foreach ($f in $script:failures) { Write-Host "  - $f" -ForegroundColor Red }
    exit 1
}
# Exit 2, not 0: a target metric with no data source is "not measured", and reporting it
# with the same exit code as a clean run is exactly how a permanently-green nightly
# happens. Distinct from exit 1 so "unfinished" and "broken" stay distinguishable.
if ($script:notImplemented.Count -gt 0 -and -not $AllowIncomplete) {
    Write-Host ''
    Write-Host "INCOMPLETE ($($script:notImplemented.Count)) - target metric has no data source:" -ForegroundColor Yellow
    foreach ($n in $script:notImplemented) { Write-Host "  - $n" -ForegroundColor Yellow }
    Write-Host "  (pass -AllowIncomplete for an exploratory run that tolerates this)"
    exit 2
}
Write-Host ''
Write-Host "contract OK (skipped=$skip, measure-only=$measure, n/a=$($script:notImplemented.Count))  fingerprint=$fingerprint"
exit 0
