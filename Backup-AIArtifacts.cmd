@echo off
rem Backs up Claude Code, Cursor and GitHub Copilot (VS Code) to ZIP files in an "AI backup" folder in your OneDrive.
rem Double-click to run. Tools that are not installed are skipped.
rem Extra arguments are passed to each script, e.g.  Backup-AIArtifacts.cmd -DryRun   or   -Destination D:\Backup
setlocal
echo AI tools backup
echo Cursor and VS Code must be closed. The script waits until you close them when it gets to them.
for %%S in (Backup-ClaudeCode Backup-Cursor Backup-Copilot) do (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0%%S.ps1" %*
)
echo.
echo Done. Wait until OneDrive shows the files in "AI backup" as synced (green check mark).
pause
