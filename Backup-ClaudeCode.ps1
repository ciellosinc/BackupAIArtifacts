<#
.SYNOPSIS
Backs up (or restores) Claude Code chats, settings, memory, skills, plugins and sign-in to a ZIP file.

.DESCRIPTION
Included: %USERPROFILE%\.claude (without caches and temporary folders), %USERPROFILE%\.claude.json,
the Claude Code extension data of VS Code / Cursor, and the Claude desktop app's MCP config.
The ZIP goes to "<OneDrive>\AI backup" unless -Destination is given.
Claude Code can keep running: its chats are append-only files.

.EXAMPLE
.\Backup-ClaudeCode.ps1 -DryRun
Lists what would be backed up, with sizes.

.EXAMPLE
.\Backup-ClaudeCode.ps1 -Restore -ZipPath "$env:OneDriveCommercial\AI backup\AI-backup-ClaudeCode-PC1-20261020-1015.zip"
#>
[CmdletBinding()]
param(
    [string]$Destination,
    [switch]$DryRun,
    [switch]$Restore,
    [string]$ZipPath,
    [string]$ProfilePath,
    [switch]$Force,
    # Auto: 7-Zip if installed, else .NET ZipArchive. 7Zip / DotNet force one (testing)
    [ValidateSet('Auto', '7Zip', 'DotNet')][string]$Archiver = 'Auto',
    # 7-Zip -mx level 0-9; default in AIBackup.Common.ps1
    [ValidateRange(0, 9)][Nullable[int]]$CompressionLevel
)

. (Join-Path $PSScriptRoot 'AIBackup.Common.ps1')
$app = 'Claude Code'

try {
    Write-Step $app
    $claudeHome = Join-Path $script:ProfileRoot '.claude'

    if ($Restore) {
        if (-not $ZipPath) { throw 'Give the backup file with -ZipPath.' }
        if (-not $ProfilePath) { $ProfilePath = $script:ProfileRoot }
        Invoke-AIRestore -ZipPath $ZipPath -ProfilePath $ProfilePath -ProcessName 'claude' -AppName $app -Force:$Force -Archiver $Archiver
        return
    }

    if (-not (Test-Path -LiteralPath $claudeHome)) { Write-Info "$app is not used on this computer. Skipped."; return }
    if (Get-Process -Name 'claude' -ErrorAction SilentlyContinue) {
        Write-Info "$app is running. That's fine: everything saved so far is included."
    }

    # Claude Code deletes chats older than cleanupPeriodDays (default 30) at startup
    $settingsFile = Join-Path $claudeHome 'settings.json'
    $days = $null
    if (Test-Path -LiteralPath $settingsFile) {
        try { $days = Get-PropValue (Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json) 'cleanupPeriodDays' } catch { }
    }
    if ($null -eq $days -or [int]$days -lt 365) {
        Write-Warning ('Claude Code deletes chats older than {0} days. To keep them, add "cleanupPeriodDays": 99999 to {1}' -f $(if ($null -ne $days) { $days } else { 30 }), $settingsFile)
    }

    Add-BackupSource -Path $claudeHome -Group '.claude' `
        -Exclude @('cache', 'shell-snapshots', 'session-env', 'ide', 'debug', 'statsig', 'telemetry', '*.lock')
    Add-BackupSource -Path (Join-Path $script:ProfileRoot '.claude.json') -Group '.claude.json'
    Add-BackupSource -Path (Join-Path $script:ProfileRoot '.claude.json.backup*') -Group '.claude.json'
    foreach ($editor in 'Code', 'Code - Insiders', 'Cursor') {
        Add-BackupSource -Path (Join-Path $script:RoamingRoot "$editor\User\globalStorage\anthropic.claude-code") -Group "Extension data ($editor)"
    }
    Add-BackupSource -Path (Join-Path $script:RoamingRoot 'Claude\claude_desktop_config.json') -Group 'Claude desktop app config'

    $claudeExe = Get-Command 'claude' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    Invoke-AIBackup -Tool 'ClaudeCode' -AppName $app -ScriptName 'Backup-ClaudeCode.ps1' -Destination $Destination -DryRun:$DryRun -Archiver $Archiver -CompressionLevel $CompressionLevel `
        -AppVersions @{ 'Claude Code' = $(if ($claudeExe) { Get-AppVersion $claudeExe.Source } else { 'not on PATH' }) } `
        -RestoreNotes @(
            'AFTER RESTORE'
            '- Start Claude Code. If it asks you to sign in, sign in again.'
            '- Keep "cleanupPeriodDays": 99999 in .claude\settings.json so old chats are not deleted.'
        )
}
catch {
    Write-Host "   ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
