<#
.SYNOPSIS
Compares backup and restore time and ZIP size: built-in .NET ZipArchive against 7-Zip at several -mx levels.

.DESCRIPTION
For each tool, runs the real backup script once per method (each in its own Windows PowerShell 5.1 process, as users run it),
then restores each ZIP into a test folder and counts the files. Restore folders are deleted afterwards; the ZIPs are kept
in -OutDir. Results are printed and saved as results.csv and results.md in -OutDir.
7-Zip runs first, so it reads the files with a cold disk cache; .NET runs last with a warm one.
Cursor and VS Code must be closed for a clean test (the backup scripts wait until they are). Run the Copilot test from a
terminal outside VS Code.

.EXAMPLE
.\Tests\Compare-Archivers.ps1 -Tool ClaudeCode, Cursor

.EXAMPLE
.\Tests\Compare-Archivers.ps1 -Tool Copilot
#>
[CmdletBinding()]
param(
    [ValidateSet('ClaudeCode', 'Cursor', 'Copilot')][string[]]$Tool = @('ClaudeCode', 'Cursor', 'Copilot'),
    [int[]]$Levels = @(1, 5, 9),
    [string]$OutDir = (Join-Path ([IO.Path]::GetTempPath()) 'AI-backup-test'),
    [switch]$SkipRestore
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$scriptDir = Split-Path $PSScriptRoot -Parent
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Format-Size([double]$Bytes) {
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    '{0:N0} MB' -f ($Bytes / 1MB)
}

function Invoke-Script([string]$Script, [string[]]$Arguments) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptDir $Script) @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "$Script $($Arguments -join ' ') failed with exit code $LASTEXITCODE" }
    $timer.Elapsed.TotalSeconds
}

function Read-Manifest([string]$ZipFile) {
    $zip = [IO.Compression.ZipFile]::OpenRead($ZipFile)
    try {
        $reader = New-Object IO.StreamReader($zip.GetEntry('_backup-info/backup-manifest.json').Open())
        try { $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
    }
    finally { $zip.Dispose() }
}

$methods = @($Levels | ForEach-Object { [pscustomobject]@{ Name = "7-Zip -mx$_"; Archiver = '7Zip'; Level = $_ } }) +
    [pscustomobject]@{ Name = '.NET (old)'; Archiver = 'DotNet'; Level = $null }

$results = New-Object 'System.Collections.Generic.List[object]'
foreach ($t in $Tool) {
    $script = "Backup-$t.ps1"
    foreach ($m in $methods) {
        $tag = $m.Name -replace '[^A-Za-z0-9]+', ''
        $dest = Join-Path $OutDir "$t\$tag"
        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
        Write-Host "`n##### $t, $($m.Name)" -ForegroundColor Magenta

        $backupArgs = @('-Destination', $dest, '-Archiver', $m.Archiver)
        if ($null -ne $m.Level) { $backupArgs += @('-CompressionLevel', $m.Level) }
        $backupSeconds = Invoke-Script $script $backupArgs
        $zipFile = @(Get-ChildItem -LiteralPath $dest -Filter '*.zip')[0]
        $manifest = Read-Manifest $zipFile.FullName

        $restoreSeconds = $null
        $restored = $null
        if (-not $SkipRestore) {
            $restoreDir = "$dest-restore"
            $restoreSeconds = Invoke-Script $script @('-Restore', '-ZipPath', $zipFile.FullName, '-ProfilePath', $restoreDir, '-Archiver', $m.Archiver, '-Force')
            $restored = @(Get-ChildItem -LiteralPath $restoreDir -Recurse -File -Force).Count
            Remove-Item -LiteralPath $restoreDir -Recurse -Force
        }

        $results.Add([pscustomobject]@{
            Tool          = $t
            Method        = $m.Name
            Raw           = Format-Size $manifest.totalBytes
            Zip           = Format-Size $zipFile.Length
            ZipMB         = [Math]::Round($zipFile.Length / 1MB, 1)
            'Zip %'       = [Math]::Round(100 * $zipFile.Length / [Math]::Max([double]$manifest.totalBytes, 1), 1)
            'Backup s'    = [Math]::Round($backupSeconds, 1)
            'Compress s'  = $manifest.compressSeconds
            'Restore s'   = $(if ($null -ne $restoreSeconds) { [Math]::Round($restoreSeconds, 1) })
            Files         = $manifest.fileCount
            Restored      = $restored
            Skipped       = $manifest.skippedCount
            Archiver      = $manifest.archiver
        })
    }
}

[void](New-Item -ItemType Directory -Force -Path $OutDir)
$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
$results | Export-Csv -LiteralPath (Join-Path $OutDir "results-$stamp.csv") -NoTypeInformation -Encoding UTF8
$cols = 'Tool', 'Method', 'Raw', 'Zip', 'Zip %', 'Backup s', 'Compress s', 'Restore s', 'Files', 'Restored', 'Skipped'
$md = @(('| ' + ($cols -join ' | ') + ' |'), ('|' + (' --- |' * $cols.Count)))
foreach ($r in $results) { $md += '| ' + (($cols | ForEach-Object { $r.$_ }) -join ' | ') + ' |' }
$md | Set-Content -LiteralPath (Join-Path $OutDir "results-$stamp.md") -Encoding UTF8

Write-Host ''
$results | Format-Table $cols -AutoSize | Out-String -Width 250 | Write-Host
Write-Host "Backup s = whole script run (scan + compress + move). Compress s = from the manifest."
Write-Host "Results and ZIPs: $OutDir"
