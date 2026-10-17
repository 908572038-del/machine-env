# Central map of supported MCP clients: where each one stores its config and how
# a stdio server entry is shaped there. Kept in one place so the installer, the
# config merger, and -ListClients cannot disagree about paths or key names.
#
# Clients differ in two ways that matter here:
#   * the top-level key (most use "mcpServers"; VS Code's workspace file uses
#     "servers");
#   * the entry shape (some require "type":"stdio"; most accept args/env).
# Getting these wrong makes the server appear installed but never load.

function Get-McpClientNames {
    return @('copilot', 'claude-desktop', 'cursor', 'windsurf', 'vscode')
}

function Get-McpClientSpec {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )
    switch ($Name) {
        'copilot' {
            $home_ = if ([string]::IsNullOrWhiteSpace($env:COPILOT_HOME)) {
                Join-Path $env:USERPROFILE '.copilot'
            } else {
                $env:COPILOT_HOME
            }
            return @{
                Name = 'copilot'
                Display = 'GitHub Copilot (VS Code user settings)'
                ConfigPath = Join-Path $home_ 'mcp-config.json'
                ServersKey = 'mcpServers'
                IncludeType = $true
                IncludeEnv = $true
            }
        }
        'claude-desktop' {
            if ([string]::IsNullOrWhiteSpace($env:APPDATA)) {
                throw 'APPDATA is not set; cannot locate the Claude Desktop config.'
            }
            return @{
                Name = 'claude-desktop'
                Display = 'Claude Desktop'
                ConfigPath = Join-Path $env:APPDATA 'Claude\claude_desktop_config.json'
                ServersKey = 'mcpServers'
                IncludeType = $false
                IncludeEnv = $true
            }
        }
        'cursor' {
            return @{
                Name = 'cursor'
                Display = 'Cursor'
                ConfigPath = Join-Path $env:USERPROFILE '.cursor\mcp.json'
                ServersKey = 'mcpServers'
                IncludeType = $false
                IncludeEnv = $true
            }
        }
        'windsurf' {
            return @{
                Name = 'windsurf'
                Display = 'Windsurf'
                ConfigPath = Join-Path $env:USERPROFILE '.codeium\windsurf\mcp_config.json'
                ServersKey = 'mcpServers'
                IncludeType = $false
                IncludeEnv = $true
            }
        }
        'vscode' {
            # Workspace-scoped: VS Code nests under "servers" and wants a "type".
            return @{
                Name = 'vscode'
                Display = 'VS Code (workspace .vscode/mcp.json)'
                ConfigPath = Join-Path (Get-Location) '.vscode\mcp.json'
                ServersKey = 'servers'
                IncludeType = $true
                IncludeEnv = $false
            }
        }
        default {
            throw "Unknown MCP client '$Name'. Known clients: $((Get-McpClientNames) -join ', ')."
        }
    }
}

function New-McpServerEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExePath,
        [Parameter(Mandatory = $true)]
        [hashtable]$Spec
    )
    $entry = [ordered]@{}
    if ($Spec.IncludeType) { $entry['type'] = 'stdio' }
    $entry['command'] = $ExePath
    $entry['args'] = @()
    if ($Spec.IncludeEnv) { $entry['env'] = [ordered]@{} }
    return $entry
}
