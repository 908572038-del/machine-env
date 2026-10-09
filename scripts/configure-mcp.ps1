param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Install', 'Uninstall')]
    [string]$Mode,

    [Parameter(Mandatory = $true)]
    [string]$ExePath,

    [string]$ConfigPath = $(if ([string]::IsNullOrWhiteSpace($env:COPILOT_HOME)) {
        Join-Path $env:USERPROFILE '.copilot\mcp-config.json'
    } else {
        Join-Path $env:COPILOT_HOME 'mcp-config.json'
    })
)

$ErrorActionPreference = 'Stop'
$serverName = 'machine-env-cpp'
$configDirectory = Split-Path -Parent $ConfigPath
$expectedExe = [System.IO.Path]::GetFullPath($ExePath)
$skipConfigWrite = $false

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    if ($Mode -eq 'Uninstall') {
        $existing = [pscustomobject]@{}
    } else {
        $existing = [pscustomobject]@{}
    }
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
if ($existing.PSObject.Properties.Name -contains 'mcpServers' -and
    $null -ne $existing.mcpServers) {
    if ($existing.mcpServers -isnot [System.Management.Automation.PSCustomObject]) {
        throw "Refusing to modify '$ConfigPath': 'mcpServers' must be a JSON object."
    }
    foreach ($property in $existing.mcpServers.PSObject.Properties) {
        $servers[$property.Name] = $property.Value
    }
}

if ($Mode -eq 'Install') {
    if (-not (Test-Path -LiteralPath $expectedExe -PathType Leaf)) {
        throw "MCP executable does not exist: $expectedExe"
    }
    $servers[$serverName] = [ordered]@{
        type = 'stdio'
        command = $expectedExe
        env = [ordered]@{}
    }
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
    if ($property.Name -ne 'mcpServers') {
        $merged[$property.Name] = $property.Value
    }
}
if ($servers.Count -gt 0) {
    $merged['mcpServers'] = $servers
}

if (-not (Test-Path -LiteralPath $configDirectory)) {
    New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
}
if (-not $skipConfigWrite -and
    ($Mode -eq 'Install' -or (Test-Path -LiteralPath $ConfigPath))) {
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
    } finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

Write-Output "MCP configuration updated: $ConfigPath"
