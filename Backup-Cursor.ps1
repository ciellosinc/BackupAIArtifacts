<#
.SYNOPSIS
Backs up (or restores) Cursor chats, settings, rules, skills, MCP config and sign-in to a ZIP file.

.DESCRIPTION
Cursor keeps all chats in one SQLite database, %APPDATA%\Cursor\User\globalStorage\state.vscdb
(several GB for heavy users), and links them to project folders through workspaceStorage.
Included: that database, workspaceStorage, settings, keybindings, snippets, profiles, and the
configuration parts of %USERPROFILE%\.cursor. Extensions are not copied, only their list.
Cursor must be closed; the script waits until it is.
The ZIP goes to "<OneDrive>\AI backup" unless -Destination is given.

.EXAMPLE
.\Backup-Cursor.ps1 -DryRun
Lists what would be backed up, with sizes.

.EXAMPLE
.\Backup-Cursor.ps1 -Restore -ZipPath "$env:OneDriveCommercial\AI backup\AI-backup-Cursor-PC1-20261020-1015.zip"
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
$app = 'Cursor'

try {
    Write-Step $app
    $userDir = Join-Path $script:RoamingRoot 'Cursor\User'
    $cursorHome = Join-Path $script:ProfileRoot '.cursor'

    if ($Restore) {
        if (-not $ZipPath) { throw 'Give the backup file with -ZipPath.' }
        if (-not $ProfilePath) { $ProfilePath = $script:ProfileRoot }
        Invoke-AIRestore -ZipPath $ZipPath -ProfilePath $ProfilePath -ProcessName 'Cursor' -AppName $app -Force:$Force -Archiver $Archiver
        return
    }

    if (-not (Test-Path -LiteralPath $userDir) -and -not (Test-Path -LiteralPath $cursorHome)) {
        Write-Info "$app is not used on this computer. Skipped."
        return
    }
    if (-not $DryRun) { Wait-AppClosed -ProcessName 'Cursor' -AppName $app -Force:$Force }

    # Settings
    Add-BackupSource -Path "$userDir\*.json" -Group 'Settings and keybindings'
    Add-BackupSource -Path "$userDir\snippets" -Group 'Settings and keybindings'
    Add-BackupSource -Path "$userDir\profiles" -Group 'Profiles' -Exclude @('*.vscdb.backup')

    # Chats: state.vscdb is the chat database (and holds the Cursor sign-in)
    Add-BackupSource -Path "$userDir\globalStorage\state.vscdb*" -Group 'Chats (global database)' -Exclude @('*.backup')
    Add-BackupSource -Path "$userDir\globalStorage\storage.json" -Group 'Chats (global database)'
    # globalStorage\anysphere.* holds only the downloaded agent CLI (node.exe per version, ~1.5 GB); Cursor fetches it again
    Add-BackupSource -Path "$userDir\workspaceStorage" -Group 'Chats (per project)' -Exclude @('*.vscdb.backup')

    # %USERPROFILE%\.cursor: configuration only, not extensions, worktrees or logs
    foreach ($name in 'mcp.json', 'cli-config.json', 'argv.json', 'ide_state.json', 'unified_repo_list.json') {
        Add-BackupSource -Path "$cursorHome\$name" -Group '.cursor config'
    }
    foreach ($name in 'rules', 'skills', 'agents', 'commands', 'plans', 'projects', 'plugins', 'snapshots', 'chats') {
        Add-BackupSource -Path "$cursorHome\$name" -Group ".cursor\$name"
    }

    $extensions = Get-ExtensionList "$cursorHome\extensions\extensions.json"
    Invoke-AIBackup -Tool 'Cursor' -AppName $app -ScriptName 'Backup-Cursor.ps1' -Destination $Destination -DryRun:$DryRun -Archiver $Archiver -CompressionLevel $CompressionLevel `
        -InfoFiles @{ 'extensions-Cursor.txt' = ($extensions -join "`r`n") } `
        -AppVersions @{ Cursor = Get-AppVersion @("$env:LOCALAPPDATA\Programs\cursor\Cursor.exe", "$env:ProgramFiles\cursor\Cursor.exe") } `
        -RestoreNotes @(
            'AFTER RESTORE'
            '- Start Cursor and sign in if asked.'
            ('- Reinstall your extensions ({0} in _backup-info\extensions-Cursor.txt). In PowerShell:' -f $extensions.Count)
            '  Get-Content "$HOME\_backup-info\extensions-Cursor.txt" | ForEach-Object { cursor --install-extension ($_ -split "@")[0] }'
        )
}
catch {
    Write-Host "   ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
