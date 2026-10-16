<#
Shared helpers for Backup-ClaudeCode.ps1, Backup-Cursor.ps1 and Backup-Copilot.ps1.
Dot-sourced by those scripts; not meant to be run on its own.
Windows PowerShell 5.1, no extra modules. 7-Zip is used when installed (faster); otherwise .NET ZipArchive.

Paths inside the backup ZIP mirror the user profile (.claude\..., AppData\Roaming\Cursor\User\...),
so restoring is the same as extracting the ZIP into C:\Users\<name>.
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$script:AIBackupVersion = '1.1 (2026-10-16)'
# 7-Zip -mx level (0 = store ... 9 = ultra); .NET ZipArchive always uses CompressionLevel.Optimal.
# -mx1: Cursor 4 GB in 42 s vs 84 s with .NET, ZIP 3 % bigger; -mx5 took 287 s (one big file = one thread). Tests 16 Oct 2026.
$script:DefaultCompressionLevel = 1
$script:ProfileRoot = [Environment]::GetFolderPath('UserProfile').TrimEnd('\')
$script:RoamingRoot = [Environment]::GetFolderPath('ApplicationData').TrimEnd('\')
$script:InfoFolder = '_backup-info'
# Existing files with these names are copied to *.pre-restore before a restore overwrites them
$script:ProtectOnRestore = @('*.vscdb', '*.db', 'settings.json', 'keybindings.json', 'mcp.json', '.claude.json', '.credentials.json', 'config.json')

$script:Items = New-Object 'System.Collections.Generic.List[object]'
$script:SeenEntries = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$script:Skipped = New-Object 'System.Collections.Generic.List[object]'

function Write-Step([string]$Text) { Write-Host ''; Write-Host "== $Text" -ForegroundColor Cyan }
function Write-Info([string]$Text) { Write-Host "   $Text" }

function Format-Size([double]$Bytes) {
    if ($Bytes -ge 1GB) { return '{0:N1} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N0} MB' -f ($Bytes / 1MB) }
    '{0:N0} KB' -f ($Bytes / 1KB)
}

function Format-Duration([TimeSpan]$Time) {
    if ($Time.TotalSeconds -lt 10) { return '{0:N1} s' -f $Time.TotalSeconds }
    if ($Time.TotalSeconds -lt 60) { return '{0:N0} s' -f $Time.TotalSeconds }
    '{0} min {1} s' -f [int][Math]::Floor($Time.TotalMinutes), $Time.Seconds
}

function Get-PropValue($Object, [string]$Name) {
    if ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
    $null
}

function Get-LongPath([string]$Path) {
    # Windows PowerShell 5.1 can't open paths over 260 characters unless they use the \\?\ prefix
    if ($Path.Length -lt 240 -or $Path.StartsWith('\\?\')) { return $Path }
    if ($Path.StartsWith('\\')) { return '\\?\UNC\' + $Path.Substring(2) }
    '\\?\' + $Path
}

function ConvertTo-EntryName([string]$FullName) {
    # Roaming is checked first so a redirected AppData still lands in the standard layout
    if ($FullName.StartsWith($script:RoamingRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        $rel = 'AppData\Roaming\' + $FullName.Substring($script:RoamingRoot.Length + 1)
    }
    elseif ($FullName.StartsWith($script:ProfileRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        $rel = $FullName.Substring($script:ProfileRoot.Length + 1)
    }
    else { throw "Path is outside the user profile: $FullName" }
    $rel.Replace('\', '/')
}

function Test-Excluded([string]$RelPath, [string[]]$Exclude) {
    foreach ($pattern in $Exclude) { if ($RelPath -like $pattern) { return $true } }
    $false
}

function Add-BackupFile([IO.FileInfo]$File, [string]$Group) {
    $entry = ConvertTo-EntryName $File.FullName
    if ($script:SeenEntries.Add($entry)) {
        $script:Items.Add([pscustomobject]@{ File = $File; Entry = $entry; Group = $Group })
    }
}

function Add-BackupSource {
    <#
    Adds a file or a folder tree to the backup list. $Path may contain wildcards; missing paths are ignored.
    $Exclude patterns (-like) are matched against the path relative to each matched folder:
    'cache' skips only the top-level cache folder, '*.vscdb.backup' skips that file type at any depth.
    Junctions and symbolic links are not followed.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Group,
        [string[]]$Exclude = @()
    )
    foreach ($item in @(Get-Item -Path $Path -Force -ErrorAction SilentlyContinue)) {
        if ($item -is [IO.FileInfo]) {
            if (-not (Test-Excluded $item.Name $Exclude)) { Add-BackupFile $item $Group }
            continue
        }
        $root = $item.FullName.TrimEnd('\')
        $stack = New-Object System.Collections.Stack
        $stack.Push($item)
        while ($stack.Count -gt 0) {
            $dir = $stack.Pop()
            try { $children = $dir.GetFileSystemInfos() }
            catch { $script:Skipped.Add([pscustomobject]@{ Path = $dir.FullName; Reason = $_.Exception.Message }); continue }
            foreach ($child in $children) {
                if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                $rel = $child.FullName.Substring($root.Length + 1)
                if (Test-Excluded $rel $Exclude) { continue }
                if ($child -is [IO.DirectoryInfo]) { $stack.Push($child) } else { Add-BackupFile $child $Group }
            }
        }
    }
}

function Wait-AppClosed {
    # Chat databases are only consistent when the app is closed. Waits until it is, unless -Force.
    # Polls instead of asking for Enter, so it also works when an AI agent or a non-interactive shell runs the script.
    param([string[]]$ProcessName, [string]$AppName, [switch]$Force)
    $asked = $false
    while (@(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue).Count -gt 0) {
        if ($Force) {
            Write-Warning "$AppName is running. Continuing because of -Force; the copy of its chat database may be incomplete."
            return
        }
        if (-not $asked) {
            Write-Host "   $AppName is open. Close all $AppName windows; the backup starts as soon as they are closed (Ctrl+C cancels)." -ForegroundColor Yellow
            $asked = $true
        }
        Start-Sleep -Seconds 2
    }
}

function Get-DefaultDestination {
    # OneDrive for work or school first, then personal OneDrive, then the Desktop. -Destination overrides this.
    foreach ($folder in $env:OneDriveCommercial, $env:OneDriveConsumer, $env:OneDrive) {
        if ($folder -and (Test-Path -LiteralPath $folder)) { return (Join-Path $folder 'AI backup') }
    }
    Write-Warning 'No OneDrive folder found. The backup goes to your Desktop; copy it to a safe place yourself.'
    Join-Path ([Environment]::GetFolderPath('Desktop')) 'AI backup'
}

function Assert-FreeSpace([string]$Path, [long]$Bytes) {
    try {
        $root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Path))
        $free = (New-Object IO.DriveInfo($root)).AvailableFreeSpace
    }
    catch { return }   # network paths: let the copy itself fail if space runs out
    if ($free -lt $Bytes) {
        throw ('Not enough free space on {0}: {1} free, up to {2} needed.' -f $root, (Format-Size $free), (Format-Size $Bytes))
    }
}

function Get-AppVersion([string[]]$ExePath) {
    foreach ($exe in $ExePath) {
        if ($exe -and (Test-Path -LiteralPath $exe)) { return (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion }
    }
    'not found'
}

function Find-7Zip {
    # 7-Zip is optional. Its default install folder first, then the folder its installer writes to the registry.
    $dirs = @("$env:ProgramW6432\7-Zip", "$env:ProgramFiles\7-Zip", "${env:ProgramFiles(x86)}\7-Zip")
    foreach ($key in 'HKLM:\SOFTWARE\7-Zip', 'HKCU:\SOFTWARE\7-Zip') {
        $props = Get-ItemProperty $key -ErrorAction SilentlyContinue
        $dirs += @((Get-PropValue $props 'Path64'), (Get-PropValue $props 'Path'))
    }
    foreach ($dir in $dirs) {
        if (-not $dir) { continue }
        $exe = Join-Path $dir '7z.exe'
        if (Test-Path -LiteralPath $exe) { return $exe }
    }
    $null
}

function Invoke-7Zip([string]$Exe, [string]$Arguments, [string]$WorkingDirectory) {
    <#
    Runs 7z.exe with its progress shown in this console. Exit code 1 means some files were skipped;
    they are returned as Path (as 7-Zip printed it) and Reason, from 7-Zip's warnings summary.
    #>
    $errFile = Join-Path ([IO.Path]::GetTempPath()) ('AI-backup-7z-{0}.txt' -f [guid]::NewGuid().ToString('N'))
    try {
        $p = Start-Process -FilePath $Exe -ArgumentList $Arguments -WorkingDirectory $WorkingDirectory `
            -NoNewWindow -PassThru -RedirectStandardError $errFile
        [void]$p.Handle   # without this, ExitCode stays empty after WaitForExit
        $p.WaitForExit()
        $lines = @(if (Test-Path -LiteralPath $errFile) { Get-Content -LiteralPath $errFile -Encoding UTF8 })
    }
    finally { Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue }
    $warnings = New-Object 'System.Collections.Generic.List[object]'
    $inSummary = $false
    foreach ($line in $lines) {
        # "Scan WARNINGS for files and folders:" / "WARNINGS for files:", then "<path> : <message>" lines up to "----"
        if ($line -match 'WARNINGS for files') { $inSummary = $true; continue }
        if ($line -like '----*') { $inSummary = $false; continue }
        if ($inSummary -and $line -match '^(.+?) : (.+)$') { $warnings.Add([pscustomobject]@{ Path = $Matches[1]; Reason = $Matches[2] }) }
    }
    [pscustomobject]@{
        ExitCode = $p.ExitCode
        Warnings = $warnings
        Errors   = (@($lines | Where-Object { $_ -match 'ERROR' }) -join ' ')
    }
}

function Get-ExtensionList([string]$ExtensionsJson) {
    # extensions.json is VS Code's (and Cursor's) list of installed extensions
    if (-not (Test-Path -LiteralPath $ExtensionsJson)) { return @() }
    try { $list = Get-Content -LiteralPath $ExtensionsJson -Raw | ConvertFrom-Json }
    catch { return @() }
    @($list | ForEach-Object {
        $id = Get-PropValue (Get-PropValue $_ 'identifier') 'id'
        if ($id) { '{0}@{1}' -f $id, (Get-PropValue $_ 'version') }
    } | Sort-Object -Unique)
}

function Add-TextEntry($Zip, [string]$Name, [string]$Text) {
    $entry = $Zip.CreateEntry($Name)
    $writer = New-Object IO.StreamWriter($entry.Open(), (New-Object Text.UTF8Encoding($false)))
    try { $writer.Write($Text) } finally { $writer.Dispose() }
}

function Get-RestoreText([string]$AppName, [string]$ScriptName, [string[]]$Notes) {
    $lines = @(
        "AI tools backup: $AppName"
        ('Created {0:yyyy-MM-dd HH:mm} on {1} by {2}.' -f (Get-Date), $env:COMPUTERNAME, $env:USERNAME)
        "Original profile folder: $script:ProfileRoot"
        ''
        'HOW TO RESTORE'
        "1. Close $AppName."
        '2. Extract this ZIP into your user profile folder (C:\Users\<your user name>) and choose to replace existing files.'
        '   The folders inside the ZIP (.claude, .cursor, AppData\Roaming\...) then land where the app expects them.'
        "   Or run the backup script:  .\$ScriptName -Restore -ZipPath `"<path to this ZIP>`""
        '3. You can delete the _backup-info folder from your profile folder afterwards.'
    )
    if ($Notes) { $lines += @('') + $Notes }
    $lines += @(
        ''
        'GOOD TO KNOW'
        '- Chats are linked to the folder a project was opened from. They show up again only for projects opened from the same path as before.'
        '- This ZIP contains your sign-ins to these tools. Do not share it.'
        '- More information: https://github.com/ciellosinc/BackupAIArtifacts'
    )
    $lines -join "`r`n"
}

function Get-InfoTexts($Manifest, $InfoTexts) {
    # The files for _backup-info: the manifest first, then README-RESTORE.txt and the extension lists
    $all = [ordered]@{ 'backup-manifest.json' = ($Manifest | ConvertTo-Json -Depth 5) }
    foreach ($key in $InfoTexts.Keys) { $all[$key] = $InfoTexts[$key] }
    $all
}

function Write-ZipDotNet([string]$ZipFile, $Items, [long]$Total, [string]$AppName, $Manifest, $InfoTexts, [Diagnostics.Stopwatch]$Clock) {
    # Built-in method: .NET ZipArchive, one file at a time. Returns the number of files added.
    $added = 0
    $done = [long]0
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $stream = [IO.File]::Open($ZipFile, [IO.FileMode]::Create, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $zip = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($i in $Items) {
            if ($timer.ElapsedMilliseconds -gt 500) {
                Write-Progress -Activity "Backing up $AppName" -Status ('{0} of {1}' -f (Format-Size $done), (Format-Size $Total)) `
                    -PercentComplete ([int](100 * $done / [Math]::Max($Total, 1)))
                $timer.Restart()
            }
            try {
                # Shared read, so files another program has open are still copied
                $in = [IO.File]::Open((Get-LongPath $i.File.FullName),[IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete')
                try {
                    $entry = $zip.CreateEntry($i.Entry, [IO.Compression.CompressionLevel]::Optimal)
                    try { $entry.LastWriteTime = [DateTimeOffset]$i.File.LastWriteTime } catch { }
                    $out = $entry.Open()
                    try { $in.CopyTo($out, 1MB) } finally { $out.Dispose() }
                }
                finally { $in.Dispose() }
                $added++
            }
            catch { $script:Skipped.Add([pscustomobject]@{ Path = $i.File.FullName; Reason = $_.Exception.Message }) }
            $done += $i.File.Length
        }

        $Manifest.fileCount = $added
        $Manifest.compressSeconds = [Math]::Round($Clock.Elapsed.TotalSeconds, 1)
        $Manifest.skippedCount = $script:Skipped.Count
        $Manifest.skipped = @($script:Skipped | Select-Object -First 200)
        $info = Get-InfoTexts $Manifest $InfoTexts
        foreach ($key in $info.Keys) { Add-TextEntry $zip "$script:InfoFolder/$key" $info[$key] }
    }
    finally {
        $zip.Dispose()
        $stream.Dispose()
        Write-Progress -Activity "Backing up $AppName" -Completed
    }
    $added
}

function Write-Zip7z([string]$ZipFile, $Items, [string]$Exe, [int]$Level, $Manifest, $InfoTexts, [Diagnostics.Stopwatch]$Clock) {
    <#
    7-Zip method: 7z.exe runs in the profile folder with a list of profile-relative paths, so the entry names are
    the same as with the built-in method. -ssw reads files other programs have open. _backup-info is added in a
    second run because the manifest lists the files 7-Zip skipped. Returns the number of files added.
    #>
    $work = Join-Path ([IO.Path]::GetTempPath()) ('AI-backup-7z-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $work $script:InfoFolder))
    try {
        $list = Join-Path $work 'files.txt'
        $utf8 = New-Object Text.UTF8Encoding($false)
        [IO.File]::WriteAllLines($list, [string[]]@($Items | ForEach-Object { $_.Entry.Replace('/', '\') }), $utf8)
        $switches = '-tzip -mx={0} -mmt=on -mcu=on -ssw -scsUTF-8 -sccUTF-8 -bso0 -bsp1 -y' -f $Level

        $run = Invoke-7Zip $Exe ('a {0} "{1}" "@{2}"' -f $switches, $ZipFile, $list) $script:ProfileRoot
        if ($run.ExitCode -gt 1) { throw ('7-Zip stopped with exit code {0}. {1}' -f $run.ExitCode, $run.Errors) }
        foreach ($w in $run.Warnings) {
            $path = if ([IO.Path]::IsPathRooted($w.Path)) { $w.Path } else { Join-Path $script:ProfileRoot $w.Path }
            $script:Skipped.Add([pscustomobject]@{ Path = $path; Reason = $w.Reason })
        }
        $added = $Items.Count - $run.Warnings.Count

        $Manifest.fileCount = $added
        $Manifest.compressSeconds = [Math]::Round($Clock.Elapsed.TotalSeconds, 1)
        $Manifest.skippedCount = $script:Skipped.Count
        $Manifest.skipped = @($script:Skipped | Select-Object -First 200)
        $info = Get-InfoTexts $Manifest $InfoTexts
        foreach ($key in $info.Keys) { [IO.File]::WriteAllText((Join-Path $work "$script:InfoFolder\$key"), $info[$key], $utf8) }
        $run = Invoke-7Zip $Exe ('a {0} "{1}" "{2}"' -f $switches, $ZipFile, $script:InfoFolder) $work
        if ($run.ExitCode -ne 0) { throw ('7-Zip could not add {0} (exit code {1}). {2}' -f $script:InfoFolder, $run.ExitCode, $run.Errors) }
    }
    finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    $added
}

function Invoke-AIBackup {
    <#
    Writes everything collected with Add-BackupSource to AI-backup-<Tool>-<computer>-<yyyyMMdd-HHmm>.zip.
    The ZIP is built in %TEMP% and moved to $Destination at the end, so OneDrive never syncs a half-written file.
    -Archiver Auto uses 7-Zip when it is installed and falls back to .NET ZipArchive; 7Zip / DotNet force one (testing).
    #>
    param(
        [Parameter(Mandatory)][string]$Tool,
        [Parameter(Mandatory)][string]$AppName,
        [Parameter(Mandatory)][string]$ScriptName,
        [string]$Destination,
        [switch]$DryRun,
        [hashtable]$InfoFiles = @{},
        [hashtable]$AppVersions = @{},
        [string[]]$RestoreNotes = @(),
        [ValidateSet('Auto', '7Zip', 'DotNet')][string]$Archiver = 'Auto',
        [Nullable[int]]$CompressionLevel
    )
    if ($null -eq $CompressionLevel) { $CompressionLevel = $script:DefaultCompressionLevel }
    $items = $script:Items
    $total = [long]0
    foreach ($i in $items) { $total += $i.File.Length }
    if ($items.Count -eq 0) { Write-Info 'Nothing to back up.'; return }

    Write-Info ('{0:N0} files, {1}:' -f $items.Count, (Format-Size $total))
    $items | Group-Object Group | ForEach-Object {
        $size = [long]0
        foreach ($i in $_.Group) { $size += $i.File.Length }
        [pscustomobject]@{ Part = $_.Name; Files = $_.Count; Size = Format-Size $size }
    } | Format-Table -AutoSize | Out-String -Width 200 | ForEach-Object { $_.TrimEnd() } | Write-Host

    if (-not $Destination) { $Destination = Get-DefaultDestination }
    if ($DryRun) {
        if ($script:Skipped.Count) { Write-Info ('{0} folders could not be read.' -f $script:Skipped.Count) }
        $sevenZipExe = if ($Archiver -ne 'DotNet') { Find-7Zip }
        Write-Info ('Destination: {0}' -f $Destination)
        Write-Info ('Archiver: {0}' -f $(if ($sevenZipExe) { "7-Zip -mx$CompressionLevel ($sevenZipExe)" } else { '.NET ZipArchive' }))
        Write-Info 'Dry run: nothing written.'
        return
    }

    $name = 'AI-backup-{0}-{1}-{2:yyyyMMdd-HHmm}.zip' -f $Tool, $env:COMPUTERNAME, (Get-Date)
    $tempDir = Join-Path ([IO.Path]::GetTempPath()) 'AI-backup'
    [void](New-Item -ItemType Directory -Force -Path $tempDir)
    [void](New-Item -ItemType Directory -Force -Path $Destination)
    Assert-FreeSpace $tempDir ($total + 100MB)
    if ([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($tempDir)) -ne [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Destination))) {
        Assert-FreeSpace $Destination ($total + 100MB)
    }

    $sevenZip = $null
    if ($Archiver -ne 'DotNet') {
        $sevenZip = Find-7Zip
        if (-not $sevenZip -and $Archiver -eq '7Zip') { throw '7-Zip (7z.exe) not found.' }
        # 7-Zip stores the paths as given, relative to the profile; a redirected AppData folder can't be expressed that way
        $outside = @($items | Where-Object { $_.File.FullName -ne (Join-Path $script:ProfileRoot $_.Entry.Replace('/', '\')) })
        if ($sevenZip -and $outside.Count) {
            Write-Info ('{0} files are outside {1} (redirected AppData). Using the built-in ZIP method.' -f $outside.Count, $script:ProfileRoot)
            $sevenZip = $null
        }
    }

    $tempZip = Join-Path $tempDir $name
    $manifest = [ordered]@{
        tool            = $Tool
        app             = $AppName
        created         = (Get-Date).ToString('o')
        computer        = $env:COMPUTERNAME
        user            = $env:USERNAME
        profilePath     = $script:ProfileRoot
        appDataPath     = $script:RoamingRoot
        scriptVersion   = $script:AIBackupVersion
        appVersions     = $AppVersions
        archiver        = ''
        compressSeconds = 0
        fileCount       = 0
        totalBytes      = $total
        skippedCount    = 0
        skipped         = @()
        infoFiles       = @($InfoFiles.Keys)
    }
    $infoTexts = [ordered]@{ 'README-RESTORE.txt' = (Get-RestoreText $AppName $ScriptName $RestoreNotes) }
    foreach ($key in $InfoFiles.Keys) { $infoTexts[$key] = $InfoFiles[$key] }

    $clock = [Diagnostics.Stopwatch]::StartNew()
    $added = $null
    if ($sevenZip) {
        $manifest.archiver = '7-Zip {0} -mx{1}' -f (Get-AppVersion $sevenZip), $CompressionLevel
        Write-Info ('Compressing with {0}' -f $manifest.archiver)
        $skippedBefore = $script:Skipped.Count
        try {
            if (Test-Path -LiteralPath $tempZip) { Remove-Item -LiteralPath $tempZip -Force }   # 7z would add to it
            $added = Write-Zip7z $tempZip $items $sevenZip $CompressionLevel $manifest $infoTexts $clock
        }
        catch {
            if ($Archiver -eq '7Zip') { throw }
            Write-Warning "7-Zip failed: $($_.Exception.Message) Trying again with the built-in ZIP method."
            while ($script:Skipped.Count -gt $skippedBefore) { $script:Skipped.RemoveAt($script:Skipped.Count - 1) }
            Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue
            $added = $null
        }
    }
    if ($null -eq $added) {
        $manifest.archiver = '.NET ZipArchive (Optimal)'
        Write-Info ('Compressing with {0}' -f $manifest.archiver)
        $added = Write-ZipDotNet $tempZip $items $total $AppName $manifest $infoTexts $clock
    }

    $target = Join-Path $Destination $name
    Move-Item -LiteralPath $tempZip -Destination $target -Force
    $clock.Stop()
    Write-Host ('   Saved: {0} ({1}, {2:N0} files, {3})' -f $target, (Format-Size (Get-Item -LiteralPath $target).Length), $added, (Format-Duration $clock.Elapsed)) -ForegroundColor Green
    if ($script:Skipped.Count) {
        Write-Warning ('{0} files or folders could not be copied. They are listed in _backup-info\backup-manifest.json inside the ZIP.' -f $script:Skipped.Count)
    }
}

function Invoke-AIRestore {
    <#
    Extracts a backup ZIP into the user profile. Existing databases and settings files are first copied to
    <name>.pre-restore. -ProfilePath restores into another folder (for testing).
    Extraction uses 7-Zip when installed (-Archiver Auto), otherwise .NET; works for ZIPs made either way.
    #>
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [string]$ProfilePath = $script:ProfileRoot,
        [string[]]$ProcessName,
        [string]$AppName,
        [switch]$Force,
        [ValidateSet('Auto', '7Zip', 'DotNet')][string]$Archiver = 'Auto'
    )
    $ZipPath = (Resolve-Path -LiteralPath $ZipPath).ProviderPath
    $ProfilePath = [IO.Path]::GetFullPath($ProfilePath).TrimEnd('\')
    $roaming = if ($ProfilePath -eq $script:ProfileRoot) { $script:RoamingRoot } else { Join-Path $ProfilePath 'AppData\Roaming' }
    if ($ProcessName) { Wait-AppClosed -ProcessName $ProcessName -AppName $AppName -Force:$Force }

    Write-Info "Restoring $ZipPath"
    Write-Info "into $ProfilePath"
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $sevenZip = $null
    if ($Archiver -ne 'DotNet') {
        $sevenZip = Find-7Zip
        if (-not $sevenZip -and $Archiver -eq '7Zip') { throw '7-Zip (7z.exe) not found.' }
        # 7-Zip extracts everything below one folder, so a redirected AppData needs the built-in method
        if ($sevenZip -and $roaming -ne (Join-Path $ProfilePath 'AppData\Roaming')) { $sevenZip = $null }
    }

    # First pass: check every path and keep copies of the databases and settings files that get replaced
    $targets = New-Object 'System.Collections.Generic.Dictionary[string,string]'
    $unsafe = 0
    $zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName.Replace('/', '\')
            if ($name.EndsWith('\') -or $name.StartsWith($script:InfoFolder + '\', [StringComparison]::OrdinalIgnoreCase)) { continue }
            if ($name.StartsWith('AppData\Roaming\', [StringComparison]::OrdinalIgnoreCase)) {
                $target = Join-Path $roaming $name.Substring('AppData\Roaming\'.Length)
            }
            else { $target = Join-Path $ProfilePath $name }
            $target = [IO.Path]::GetFullPath($target)
            if (-not ($target.StartsWith($ProfilePath + '\', [StringComparison]::OrdinalIgnoreCase) -or
                      $target.StartsWith($roaming + '\', [StringComparison]::OrdinalIgnoreCase))) {
                Write-Warning "Skipped unsafe path in ZIP: $($entry.FullName)"
                $unsafe++
                continue
            }
            if ([IO.File]::Exists($target) -and (Test-Excluded $entry.Name $script:ProtectOnRestore)) {
                if (-not [IO.File]::Exists("$target.pre-restore")) { [IO.File]::Copy($target, "$target.pre-restore") }
                # A leftover journal of the current database must not be applied to the restored one
                foreach ($suffix in '-wal', '-shm', '-journal') {
                    if ([IO.File]::Exists("$target$suffix")) { Move-Item -LiteralPath "$target$suffix" -Destination "$target$suffix.pre-restore" -Force }
                }
            }
            $targets[$entry.FullName] = $target
        }
    }
    finally { $zip.Dispose() }
    if ($unsafe) { $sevenZip = $null }   # only the built-in method skips single entries

    $method = $null
    if ($sevenZip) {
        $method = '7-Zip {0}' -f (Get-AppVersion $sevenZip)
        Write-Info "Extracting with $method"
        [void][IO.Directory]::CreateDirectory($ProfilePath)
        $run = Invoke-7Zip $sevenZip ('x "{0}" -o"{1}" -x!{2} -aoa -y -sccUTF-8 -bso0 -bsp1' -f $ZipPath, $ProfilePath, $script:InfoFolder) $ProfilePath
        foreach ($w in $run.Warnings) { Write-Warning "Not restored: $($w.Path) : $($w.Reason)" }
        if ($run.ExitCode -gt 1) {
            if ($Archiver -eq '7Zip') { throw ('7-Zip stopped with exit code {0}. {1}' -f $run.ExitCode, $run.Errors) }
            Write-Warning ('7-Zip stopped with exit code {0}. {1} Trying again with the built-in ZIP method.' -f $run.ExitCode, $run.Errors)
            $method = $null
        }
        else { $count = $targets.Count - $run.Warnings.Count }
    }
    if (-not $method) {
        $method = '.NET ZipArchive'
        Write-Info "Extracting with $method"
        $count = 0
        $zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
        try {
            foreach ($entry in $zip.Entries) {
                $target = $null
                if (-not $targets.TryGetValue($entry.FullName, [ref]$target)) { continue }
                $long = Get-LongPath $target
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($long))
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $long, $true)
                $count++
            }
        }
        finally { $zip.Dispose() }
    }
    Write-Host ('   Restored {0:N0} files in {1}. Replaced databases and settings were kept as *.pre-restore.' -f $count, (Format-Duration $clock.Elapsed)) -ForegroundColor Green
}
