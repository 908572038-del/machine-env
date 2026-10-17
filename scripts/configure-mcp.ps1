param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Install', 'Uninstall')]
    [string]$Mode,

    [Parameter(Mandatory = $true)]
    [string]$ExePath,

    # Which client's config to edit. Defaults to copilot so existing callers and
    # single-client installs keep working unchanged. Ignored when -ConfigPath is
    # supplied explicitly.
    [string]$Client = 'copilot',

    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
$serverName = 'machine-env-cpp'
$previousServerName = 'machine-env'

$registryPath = Join-Path $PSScriptRoot 'client-registry.ps1'
if (-not (Test-Path -LiteralPath $registryPath -PathType Leaf)) {
    throw "client-registry.ps1 is missing beside configure-mcp.ps1: $registryPath"
}
. $registryPath

$spec = Get-McpClientSpec -Name $Client
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = $spec.ConfigPath
}
$serversKey = $spec.ServersKey
$configDirectory = Split-Path -Parent $ConfigPath
$expectedExe = [System.IO.Path]::GetFullPath($ExePath)
$installDirectory = Split-Path -Parent $expectedExe
$skipConfigWrite = $false

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    $existing = [pscustomobject]@{}
} else {
    try {
        $existing = Get-Content -LiteralPath $ConfigPath -Encoding UTF8 -Raw |
            ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Refusing to modify invalid MCP config '$ConfigPath': $($_.Exception.Message)"
    }
    if ($null -eq $existing -or $existing -is [array] -or
        $existing -isnot [System.Management.Automation.PSCustomObject]) {
        throw "Refusing to modify '$ConfigPath': expected a JSON object."
    }
}

$servers = [ordered]@{}
if ($existing.PSObject.Properties.Name -contains $serversKey -and
    $null -ne $existing.$serversKey) {
    if ($existing.$serversKey -isnot [System.Management.Automation.PSCustomObject]) {
        throw "Refusing to modify '$ConfigPath': '$serversKey' must be a JSON object."
    }
    foreach ($property in $existing.$serversKey.PSObject.Properties) {
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

if ($Mode -eq 'Install') {
    if (-not (Test-Path -LiteralPath $expectedExe -PathType Leaf)) {
        throw "MCP executable does not exist: $expectedExe"
    }
    $servers[$serverName] = New-McpServerEntry -ExePath $expectedExe -Spec $spec
} elseif ($servers.Contains($serverName)) {
    $configuredExe = [string]$servers[$serverName].command
    if (-not [string]::IsNullOrWhiteSpace($configuredExe)) {
        try {
            $configuredExe = [System.IO.Path]::GetFullPath($configuredExe)
        } catch {
            $configuredExe = ''
        }
    }
    if ([string]::Equals(
            $configuredExe,
            $expectedExe,
            [System.StringComparison]::OrdinalIgnoreCase)) {
        $servers.Remove($serverName)
    } else {
        Write-Output 'The configured machine-env-cpp entry points elsewhere; leaving it unchanged.'
        $skipConfigWrite = $true
    }
}

$merged = [ordered]@{}
foreach ($property in $existing.PSObject.Properties) {
    if ($property.Name -ne $serversKey) {
        $merged[$property.Name] = $property.Value
    }
}
if ($servers.Count -gt 0) {
    $merged[$serversKey] = $servers
}

$wroteConfig = $false
if (-not $skipConfigWrite -and
    ($Mode -eq 'Install' -or (Test-Path -LiteralPath $ConfigPath))) {
    if (-not (Test-Path -LiteralPath $configDirectory)) {
        New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
    }
    if ((Test-Path -LiteralPath $ConfigPath) -and
        -not (Test-Path -LiteralPath "$ConfigPath.bak")) {
        Copy-Item -LiteralPath $ConfigPath -Destination "$ConfigPath.bak" -Force
    }

    $temporaryPath = "$ConfigPath.$PID.tmp"
    try {
        $json = $merged | ConvertTo-Json -Depth 40
        $encoding = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($temporaryPath, $json, $encoding)
        Move-Item -LiteralPath $temporaryPath -Destination $ConfigPath -Force
        $wroteConfig = $true
    } finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

# Report what actually happened. An uninstall over a client that was never
# registered writes nothing, and calling that "updated" hides the difference
# between "I changed your configuration" and "there was nothing to change".
if ($skipConfigWrite) {
    Write-Output "MCP configuration left unchanged for '$Client': $ConfigPath (the existing machine-env-cpp entry points elsewhere)"
} elseif ($wroteConfig) {
    Write-Output "MCP configuration updated for '$Client': $ConfigPath"
} else {
    Write-Output "No MCP configuration to change for '$Client': $ConfigPath (file absent)"
}
