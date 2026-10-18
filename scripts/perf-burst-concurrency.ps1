<#
.SYNOPSIS
    Concurrency burst harness for machine-env-cpp: latency, thread/handle/WS peaks
    and (once Phase 5 lands) real-probe counts per burst.

.DESCRIPTION
    Injects N JSON-RPC requests into ONE server process over stdin, timestamps every
    response line as it arrives, and samples the server process from a side runspace.

    Fixture (fixed on purpose, so numbers stay comparable across runs):
      * network probes: get_network with skip_endpoints=["__none__"] (bypasses cache,
        touches all 4 endpoints) and timeout_ms=1200 (a fixture value, NOT the default;
        the default stays 1500, and 1200 leases up to the 1500 budget tier).
      * K = 1 distinct attempt signature unless a case says otherwise.
      * cache is cold for network on this machine: a probe that exhausts its budget is
        never written to the on-disk cache, so every network case here is a real probe.

    Sampling: a side runspace polls Threads / HandleCount / WorkingSet64 of every
    machine-env-cpp process. Default interval -SampleIntervalMs 15 (see param help).
    The harness assumes one server instance at a time (true on a CI runner); with two
    instances the peak would be the max over both and is not attributable.

    Verdicts:
      PASS  contract holds (ids complete, latency inside its own budget, no crash)
      FAIL  contract violated -> exit code 1
      SKIP  precondition absent (a Phase 5 target metric with no field to read yet,
            or the machine did not reach the load the case needs)
      MEASURE  target metric recorded but not enforced (pre-Phase 5 baseline)

    Phase 5 targets (thread ceiling, handle ceiling, real-probe delta) are recorded
    as MEASURE by default. Pass -EnforcePhase5Targets to make them FAIL-able; flip
    that on only after dedupe + per-endpoint negative cache have landed.

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

# "powershell -File script.ps1 -Cases peak,base" passes the literal string "peak,base",
# which binds to [string[]] as ONE element, so split on commas here as well.
$Cases = @($Cases | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$knownCases = @('base', 'peak', 'bypass', 'plain', 'refresh', 'cheap', 'warm')
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
Write-Host "started      : $stamp"
Write-Host "targets      : $(if ($EnforcePhase5Targets) { 'ENFORCED' } else { 'measure-only until Phase 5 lands' })"
Write-Host ''

$init = '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"perf-burst","version":"1"}}}'

function New-NetworkCalls {
    param([int]$Count, [switch]$Refresh, [switch]$Skip)
    # NB: PowerShell variable names are case-insensitive, so a local called $refresh
    # would *be* the [switch]$Refresh parameter and assigning a string to it fails.
    $parts = @()
    if ($Refresh) { $parts += '"refresh":true' }
    if ($Skip) { $parts += '"skip_endpoints":["__none__"]' }
    $parts += '"timeout_ms":1200'
    $parts += '"detail":false'
    $argJson = ($parts -join ',')
    for ($i = 1; $i -le $Count; $i++) {
        '{"jsonrpc":"2.0","id":' + $i + ',"method":"tools/call","params":{"name":"get_network","arguments":{' + $argJson + '}}}'
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
    param([string[]]$Requests, [string]$Label, [switch]$WithReadings, [int]$SettleMs = 450)

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
    if ($WithReadings) { $env:MACHINE_ENV_DIAG = '1' }
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
        if ($WithReadings) { Remove-Item Env:MACHINE_ENV_DIAG -ErrorAction SilentlyContinue }
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
            # diag seq=<n> tool=<name> attempts=<u64> inflight_peak=<u64> reordered=<u64> max_hold_ms=<n>
            $d = [regex]::Match($text, 'diag seq=(\d+).*?attempts=(\d+).*?inflight_peak=(\d+).*?reordered=(\d+).*?max_hold_ms=(\d+)')
            if ($d.Success) {
                $diag.Add([pscustomobject]@{
                        seq      = [int]$d.Groups[1].Value
                        attempts = [double]$d.Groups[2].Value
                        inflight = [double]$d.Groups[3].Value
                        reordered = [double]$d.Groups[4].Value
                        maxHold  = [int]$d.Groups[5].Value
                    })
            }
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
        $responses.Add([pscustomobject]@{
                id       = $id
                arrive   = $arrive
                elapsed  = $(if ($elapsedMatch.Success) { [double]$elapsedMatch.Groups[1].Value } else { [double]::NaN })
                attempts = $(if ($attemptMatch.Success) { [double]$attemptMatch.Groups[1].Value } else { [double]::NaN })
                inflight = $(if ($inflightMatch.Success) { [double]$inflightMatch.Groups[1].Value } else { [double]::NaN })
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

    [pscustomobject]@{
        Label     = $Label
        Wall      = $sw.ElapsedMilliseconds
        Responses = $responses
        Stderr    = $stderr
        Peaks     = $peaks
        Expected  = $Requests.Count
    }
}

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
# dispatch call probe_network directly (main.cpp:1150-1152), so this never touches
# the cache lock: it is the pure "N requests = N probes, all in parallel" shape.
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
    $b = Invoke-Burst -Requests (New-NetworkCalls -Count 100) -Label 'plain-n100'
    $p99 = Get-Quantile -Values @($b.Responses | ForEach-Object { $_.arrive }) -Q 0.99
    $ok = Assert-Contract -Ok ($b.Responses.Count -eq 100) -Case 'plain-n100' -Message "expected 100 responses, got $($b.Responses.Count)"
    $fast = Assert-Contract -Ok ($p99 -le 1350) -Case 'plain-n100' -Message "p99 $p99 ms exceeds budget+150"
    Add-Row -Case 'plain-n100' -Verdict $(if ($ok -and $fast) { 'PASS' } else { 'FAIL' }) -Detail `
    ("wall={0}ms p99={1}ms thr={2} hnd={3} ws={4}MB" -f $b.Wall, $p99, $b.Peaks.threads, $b.Peaks.handles, $b.Peaks.ws)
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
    $b = Invoke-Burst -Requests (New-NetworkCalls -Count 100 -Refresh) -Label 'refresh-n100'
    $p50 = Get-Quantile -Values @($b.Responses | ForEach-Object { $_.arrive }) -Q 0.5
    $p99 = Get-Quantile -Values @($b.Responses | ForEach-Object { $_.arrive }) -Q 0.99
    $ids = @($b.Responses | ForEach-Object { $_.id })
    $ok = Assert-Contract -Ok (($ids.Count -eq 100) -and ((($ids | Sort-Object -Unique).Count) -eq 100)) -Case 'refresh-n100' -Message "expected 100 distinct ids, got $($ids.Count)"
    $stderrHit = ($b.Stderr -join "`n")
    Add-Row -Case 'refresh-n100' -Verdict $(if ($ok) { 'PASS' } else { 'FAIL' }) -Detail `
    ("wall={0}ms p50={1}ms p99={2}ms thr={3} hnd={4} ws={5}MB" -f $b.Wall, $p50, $p99, $b.Peaks.threads, $b.Peaks.handles, $b.Peaks.ws)

    $attempts = @($b.Responses | ForEach-Object { $_.attempts } | Where-Object { -not [double]::IsNaN($_) })
    if ($attempts.Count -eq 0) {
        Add-Row -Case 'refresh-n100/attempts' -Verdict 'SKIP' -Detail '_meta.probe_attempts_started_total absent (Phase 5 not landed)'
    } else {
        $delta = ($attempts | Measure-Object -Maximum).Maximum
        if ($delta -le 2) {
            Add-Row -Case 'refresh-n100/attempts' -Verdict 'PASS' -Detail "attempts delta $delta <= 2 (no stampede)"
        } elseif ($EnforcePhase5Targets) {
            $script:failures.Add("refresh-n100 : attempts delta $delta > 2")
            Add-Row -Case 'refresh-n100/attempts' -Verdict 'FAIL' -Detail "attempts delta $delta > 2 (stampede)"
        } else {
            Add-Row -Case 'refresh-n100/attempts' -Verdict 'MEASURE' -Detail "attempts delta $delta (pre-dedupe baseline)"
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
# per-process). Needs probe_attempts_started_total to be judgeable; without it
# the case is SKIP rather than a guess.
# ---------------------------------------------------------------------------
if ($Cases -contains 'warm') {
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add($init)
    foreach ($r in (New-NetworkCalls -Count 100)) { $lines.Add($r) }
    foreach ($r in (New-NetworkCalls -Count 100)) { $lines.Add($r) }
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
    }
    $attempts = @()
    $round2Arrive = @()
    foreach ($line in $raw) {
        $cut = $line.IndexOf('|'); if ($cut -lt 0) { continue }
        $text = $line.Substring($cut + 1).Trim()
        if (-not $text.StartsWith('{')) { continue }
        $attemptMatch = [regex]::Match($text, '"probe_attempts_started_total":(\d+)')
        $idMatch = [regex]::Match($text, '"id":(\d+)')
        if (-not $attemptMatch.Success -or -not $idMatch.Success) { continue }
        $attempts += [double]$attemptMatch.Groups[1].Value
        if ([int]$idMatch.Groups[1].Value -gt 100) { $round2Arrive += [int]$line.Substring(0, $cut) }
    }
    if ($attempts.Count -eq 0) {
        Add-Row -Case 'warm-r2' -Verdict 'SKIP' -Detail '_meta.probe_attempts_started_total absent (Phase 5 not landed)'
    } else {
        $delta = (($attempts | Measure-Object -Maximum).Maximum) - (($attempts | Measure-Object -Minimum).Minimum)
        $p50 = Get-Quantile -Values $round2Arrive -Q 0.5
        if ($delta -le 0) {
            Add-Row -Case 'warm-r2' -Verdict 'PASS' -Detail ("round2 attempts delta {0}, p50 {1}ms (negative cache hit)" -f $delta, $p50)
        } elseif ($EnforcePhase5Targets) {
            $script:failures.Add("warm-r2 : attempts delta $delta, expected 0 inside TTL")
            Add-Row -Case 'warm-r2' -Verdict 'FAIL' -Detail ("round2 attempts delta {0} != 0 (budget tier key mismatch?)" -f $delta)
        } else {
            Add-Row -Case 'warm-r2' -Verdict 'MEASURE' -Detail ("round2 attempts delta {0}, p50 {1}ms" -f $delta, $p50)
        }
    }
}

Write-Host ''
$reportPath = Join-Path $OutDir ("burst-{0}.csv" -f ([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')))
$script:rows | Export-Csv -Path $reportPath -NoTypeInformation -Encoding UTF8
Write-Host "report: $reportPath"

$skip = @($script:rows | Where-Object { $_.verdict -eq 'SKIP' }).Count
$measure = @($script:rows | Where-Object { $_.verdict -eq 'MEASURE' }).Count
if ($script:failures.Count -gt 0) {
    Write-Host ''
    Write-Host "CONTRACT VIOLATIONS ($($script:failures.Count)):" -ForegroundColor Red
    foreach ($f in $script:failures) { Write-Host "  - $f" -ForegroundColor Red }
    exit 1
}
Write-Host ''
Write-Host "contract OK (skipped=$skip, measure-only=$measure)  fingerprint=$fingerprint"
exit 0
