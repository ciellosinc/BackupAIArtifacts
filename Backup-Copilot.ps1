<#
.SYNOPSIS
Backs up (or restores) GitHub Copilot chats and VS Code settings, prompts, MCP config and the Copilot CLI config to a ZIP file.

.DESCRIPTION
VS Code keeps Copilot chats per project folder in %APPDATA%\Code\User\workspaceStorage\<id>\chatSessions,
and chats without a folder in globalStorage\emptyWindowChatSessions.
Included for VS Code and, if installed, VS Code Insiders: settings, keybindings, MCP config, prompts,
snippets, profiles, chat sessions and edit sessions, Copilot memory, plus %USERPROFILE%\.copilot.
Not included: other extensions' data, caches, logs, Copilot embedding caches. Extensions are not copied,
only their list. VS Code must be closed; the script waits until it is.
The ZIP goes to "<OneDrive>\AI backup" unless -Destination is given.

.EXAMPLE
.\Backup-Copilot.ps1 -DryRun
Lists what would be backed up, with sizes.

.EXAMPLE
.\Backup-Copilot.ps1 -Restore -ZipPath "$env:OneDriveCommercial\AI backup\AI-backup-Copilot-PC1-20261020-1015.zip"
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
$app = 'VS Code'
$editions = @(
    @{ Name = 'VS Code';          Dir = 'Code';            Process = 'Code';            Extensions = '.vscode';          Cli = 'code'
       Exe = @("$env:LOCALAPPDATA\Programs\Microsoft VS Code\Code.exe", "$env:ProgramFiles\Microsoft VS Code\Code.exe") }
    @{ Name = 'VS Code Insiders'; Dir = 'Code - Insiders'; Process = 'Code - Insiders'; Extensions = '.vscode-insiders'; Cli = 'code-insiders'
       Exe = @("$env:LOCALAPPDATA\Programs\Microsoft VS Code Insiders\Code - Insiders.exe", "$env:ProgramFiles\Microsoft VS Code Insiders\Code - Insiders.exe") }
)

try {
    Write-Step 'GitHub Copilot (VS Code)'

    if ($Restore) {
        if (-not $ZipPath) { throw 'Give the backup file with -ZipPath.' }
        if (-not $ProfilePath) { $ProfilePath = $script:ProfileRoot }
        Invoke-AIRestore -ZipPath $ZipPath -ProfilePath $ProfilePath -ProcessName ($editions | ForEach-Object { $_.Process }) -AppName $app -Force:$Force -Archiver $Archiver
        return
    }

    $found = @($editions | Where-Object { Test-Path -LiteralPath (Join-Path $script:RoamingRoot "$($_.Dir)\User") })
    $copilotHome = Join-Path $script:ProfileRoot '.copilot'
    if ($found.Count -eq 0 -and -not (Test-Path -LiteralPath $copilotHome)) { Write-Info "$app is not used on this computer. Skipped."; return }
    if (-not $DryRun) {
        foreach ($e in $found) { Wait-AppClosed -ProcessName $e.Process -AppName $e.Name -Force:$Force }
    }

    $infoFiles = @{}
    $versions = @{}
    $notes = @('AFTER RESTORE', '- Start VS Code and sign in to GitHub again if asked.')
    foreach ($e in $found) {
        $userDir = Join-Path $script:RoamingRoot "$($e.Dir)\User"
        $tag = $e.Name

        # Settings, keybindings, MCP servers, prompts and instructions
        Add-BackupSource -Path "$userDir\*.json" -Group "$tag settings"
        Add-BackupSource -Path "$userDir\*.code-workspace" -Group "$tag settings"
        foreach ($name in 'prompts', 'snippets', 'mcp') { Add-BackupSource -Path "$userDir\$name" -Group "$tag settings" }
        Add-BackupSource -Path "$userDir\profiles" -Group "$tag profiles" -Exclude @('*.vscdb.backup')

        # Chats without a project folder, Copilot memory and agent data
        Add-BackupSource -Path "$userDir\globalStorage\state.vscdb*" -Group "$tag chats (global)" -Exclude @('*.backup')
        Add-BackupSource -Path "$userDir\globalStorage\storage.json" -Group "$tag chats (global)"
        Add-BackupSource -Path "$userDir\globalStorage\emptyWindowChatSessions" -Group "$tag chats (global)"
        Add-BackupSource -Path "$userDir\globalStorage\github.copilot-chat" -Group "$tag Copilot data" `
            -Exclude @('*Embeddings*', 'debug-logs', 'logContextRecordings')

        # Chats per project folder
        foreach ($name in 'workspace.json', 'state.vscdb', 'chatSessions', 'chatEditingSessions', 'GitHub.copilot-chat') {
            Add-BackupSource -Path "$userDir\workspaceStorage\*\$name" -Group "$tag chats (per project)"
        }

        $extensions = Get-ExtensionList (Join-Path $script:ProfileRoot "$($e.Extensions)\extensions\extensions.json")
        $listName = 'extensions-{0}.txt' -f $e.Dir.Replace(' ', '')
        $infoFiles[$listName] = $extensions -join "`r`n"
        $versions[$e.Name] = Get-AppVersion $e.Exe
        $notes += @(
            ('- Reinstall your {0} extensions ({1} in _backup-info\{2}). In PowerShell:' -f $e.Name, $extensions.Count, $listName)
            ('  Get-Content "$HOME\_backup-info\{0}" | ForEach-Object {{ {1} --install-extension ($_ -split "@")[0] }}' -f $listName, $e.Cli)
        )
    }

    # GitHub Copilot CLI: config, MCP servers, skills, agents, sessions
    Add-BackupSource -Path $copilotHome -Group '.copilot (Copilot CLI)' -Exclude @('logs', 'ide', 'pkg', 'cache', '*.lock')

    Invoke-AIBackup -Tool 'Copilot' -AppName $app -ScriptName 'Backup-Copilot.ps1' -Destination $Destination -DryRun:$DryRun -Archiver $Archiver -CompressionLevel $CompressionLevel `
        -InfoFiles $infoFiles -AppVersions $versions -RestoreNotes $notes
}
catch {
    Write-Host "   ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
