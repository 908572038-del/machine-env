# probe_environment.ps1 — OS, shell, network and path facts; emit JSON.
#
# Emits one JSON object on stdout. Diagnostics go to stderr.
# All facts are observed, never inferred from documentation.

$ErrorActionPreference = 'SilentlyContinue'

$result = [ordered]@{
    os              = [ordered]@{}
    shell           = [ordered]@{}
    paths           = [ordered]@{}
    network         = [ordered]@{}
    probed_at       = (Get-Date).ToString('o')
}

# --- OS ---------------------------------------------------------------------
$os = Get-CimInstance Win32_OperatingSystem
if ($os) {
    $result.os['caption']        = $os.Caption
    $result.os['version']        = $os.Version
    $result.os['build']          = $os.BuildNumber
    $result.os['arch']           = $os.OSArchitecture
    $result.os['total_mem_mb']   = [math]::Round($os.TotalVisibleMemorySize / 1024)
    $result.os['free_mem_mb']    = [math]::Round($os.FreePhysicalMemory / 1024)
}

$cs = Get-CimInstance Win32_ComputerSystem
if ($cs) {
    $result.os['manufacturer'] = $cs.Manufacturer
    $result.os['model']        = $cs.Model
    $result.os['logical_cpu']  = $cs.NumberOfLogicalProcessors
}

$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
if ($cpu) {
    # Kept for completeness only. NOTE: Win32_Processor.Flags is truncated by
    # WMI and misreports AVX2 — never trust it for ISA decisions. Use probe_hw.
    $result.os['cpu_name']    = $cpu.Name
    $result.os['cpu_cores']   = $cpu.NumberOfCores
    $result.os['cpu_threads'] = $cpu.NumberOfLogicalProcessors
}

# --- Shell environment ------------------------------------------------------
$result.shell['ps_version']     = $PSVersionTable.PSVersion.ToString()
$result.shell['ps_edition']     = $PSVersionTable.PSEdition
$result.shell['ps_host']        = $Host.Name
$result.shell['current_user']   = "$env:USERDOMAIN\$env:USERNAME"
$result.shell['is_admin']       = ([Security.Principal.WindowsPrincipal] `
                                    [Security.Principal.WindowsIdentity]::GetCurrent()
                                  ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# Capabilities that change how scripts must be written.
$result.shell['supports_ampersand_ampersand'] = ($PSVersionTable.PSVersion.Major -ge 7)
$result.shell['has_heredoc']                  = ($PSVersionTable.PSVersion.Major -ge 7)
$result.shell['execution_policy']             = "$(Get-ExecutionPolicy)"

# --- Paths ------------------------------------------------------------------
$result.paths['user_profile']  = $env:USERPROFILE
$result.paths['appdata']       = $env:APPDATA
$result.paths['local_appdata'] = $env:LOCALAPPDATA
$result.paths['temp']          = $env:TEMP
$result.paths['program_files'] = $env:ProgramFiles
$result.paths['pf_x86']        = ${env:ProgramFiles(x86)}
$result.paths['path_entries']  = @($env:Path -split ';' | Where-Object { $_ })

# --- Network reachability ---------------------------------------------------
# Short timeouts: this runs inside an MCP tool call and must not stall the UI.
function Test-Endpoint {
    param([string]$Url, [int]$TimeoutSec = 4)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $r = Invoke-WebRequest -Uri $Url -Method Head -TimeoutSec $TimeoutSec `
             -UseBasicParsing -ErrorAction Stop
        $sw.Stop()
        return [ordered]@{ ok = $true; status = $r.StatusCode; ms = $sw.ElapsedMilliseconds }
    } catch {
        $sw.Stop()
        return [ordered]@{ ok = $false; error = $_.Exception.Message.Split([char]10)[0]; ms = $sw.ElapsedMilliseconds }
    }
}

$targets = [ordered]@{
    github_api = 'https://api.github.com'
    github_raw = 'https://raw.githubusercontent.com'
    huggingface = 'https://huggingface.co'
    pypi       = 'https://pypi.org'
}
foreach ($k in $targets.Keys) {
    $result.network[$k] = Test-Endpoint -Url $targets[$k]
}

$result | ConvertTo-Json -Depth 8 -Compress
