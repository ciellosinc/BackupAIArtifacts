# Backup AI Artifacts

PowerShell scripts that back up the local data of AI coding assistants on Windows to ZIP files:

- **Claude Code**
- **Cursor**
- **GitHub Copilot** in VS Code (and VS Code Insiders) plus the Copilot CLI

Chats, settings, memory, rules, skills, MCP configuration and sign-ins of these tools live only in your user profile. A new device, a reset or a reinstall loses them. By default the ZIPs go to an `AI backup` folder in your OneDrive, and the OneDrive app uploads them.

> [!WARNING]
> The ZIP files contain sign-in tokens (Claude Code `.credentials.json`, Cursor's sign-in in `state.vscdb`). Keep them in your own OneDrive or another private place. Don't share them and don't commit them to git (`.gitignore` excludes `*.zip`).

## Requirements

- Windows 10 or 11 with Windows PowerShell 5.1 (built in). No modules needed.
- Optional: [7-Zip](https://www.7-zip.org/). If it's installed, the scripts use it and run about twice as fast. Otherwise they use the built-in .NET ZIP code.
- For upload: the OneDrive app, signed in (OneDrive for work or school, or personal OneDrive).
- Cursor and VS Code must be closed while their backup runs. Claude Code can stay open.

## Quick start (people)

1. Download or clone this repository.
2. Double-click `Backup-AIArtifacts.cmd`. It runs the three backups one after the other and skips tools that aren't installed.
3. When it asks, close all Cursor and VS Code windows. The backup continues by itself once they are closed.
4. Wait until OneDrive shows the files in `AI backup` as synced (green check mark).

## Instructions for AI agents

Follow these steps when a user asks something like *"Run this script locally for all agents, then upload the backup files to my OneDrive."* Run every command in PowerShell on the user's Windows machine.

### Rules

- Don't use `-Force` for a real backup. It copies chat databases while the app is open, and the copy can be incomplete.
- Don't stop, kill or restart Cursor, VS Code or any other app yourself. Ask the user to close it.
- Don't print, open, copy or upload the contents of the ZIPs or of `.credentials.json`. Don't move the ZIPs anywhere except the folder the user chose.
- Upload means: the ZIPs are written into the local OneDrive folder, and the OneDrive app uploads them. Don't use other upload methods.
- Don't install 7-Zip or anything else without asking. The scripts work without it.

### 1. Get the scripts

```powershell
$repo = Join-Path $HOME 'BackupAIArtifacts'
if (-not (Test-Path $repo)) { git clone https://github.com/ciellosinc/BackupAIArtifacts.git $repo }
Set-Location $repo
```

If `git` isn't available, download `https://github.com/ciellosinc/BackupAIArtifacts/archive/refs/heads/main.zip` and extract it to `$HOME\BackupAIArtifacts` instead.

### 2. Choose the OneDrive folder

```powershell
"Work or school: $env:OneDriveCommercial"
"Personal:       $env:OneDriveConsumer"
Get-Process OneDrive -ErrorAction SilentlyContinue | Select-Object -First 1 Name
```

- If only one of the two is set, use it.
- If both are set, ask the user which one, unless they already said.
- If neither is set or the `OneDrive` process isn't running, tell the user that OneDrive isn't set up on this machine and ask where to save the backup instead.

```powershell
$dest = Join-Path $env:OneDriveCommercial 'AI backup'   # or $env:OneDriveConsumer
```

### 3. Dry run

Lists what each script would back up, with sizes, the destination folder and the archiver. Nothing is written.

```powershell
foreach ($s in 'Backup-ClaudeCode', 'Backup-Cursor', 'Backup-Copilot') {
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\$s.ps1" -DryRun -Destination $dest
}
```

Tell the user the total size per tool. A tool that isn't installed prints `... is not used on this computer. Skipped.`

### 4. Back up Claude Code

Claude Code can keep running, including the session you are running in.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Backup-ClaudeCode.ps1 -Destination $dest
```

### 5. Back up Cursor and VS Code (Copilot)

These must be closed, because their chats are in SQLite databases. Check what is running:

```powershell
Get-Process Cursor, Code, 'Code - Insiders' -ErrorAction SilentlyContinue | Select-Object -Unique Name
```

- **App not running:** run its script directly, as in step 4 (`Backup-Cursor.ps1`, `Backup-Copilot.ps1`).
- **App running:** this is always the case when you, the agent, run inside Cursor or VS Code. Closing that app would also stop you. Start the backup in its own window instead. The window waits until the app is closed, then backs it up:

  ```powershell
  foreach ($s in 'Backup-Cursor', 'Backup-Copilot') {
      Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$repo\$s.ps1`" -Destination `"$dest`""
  }
  ```

  Then tell the user: *"Two PowerShell windows are waiting. Save your work and close all Cursor and VS Code windows. Each backup starts by itself and ends with a green `Saved:` line. Then reopen your editor."* Start only the windows for apps that are installed (see the dry run).

### 6. Check the result

```powershell
Get-ChildItem $dest -Filter 'AI-backup-*.zip' | Sort-Object LastWriteTime | Select-Object Name, @{n='MB';e={[int]($_.Length/1MB)}}, LastWriteTime
```

- Each script prints `Saved: <path> (<size>, <n> files, <duration>)` and exits with code 0.
- Exit code 1 means an error, printed as `ERROR: ...`.
- A warning such as `5 files or folders could not be copied` lists those files in `_backup-info\backup-manifest.json` inside the ZIP. Report the count to the user.
- If Claude Code warns about `cleanupPeriodDays`, pass the warning on: Claude Code deletes old chats unless the user raises that setting.

### 7. Upload

The OneDrive app uploads the files in `$dest` by itself. Tell the user where the files are, and to wait until OneDrive shows them as synced (green check mark in Explorer, or the files visible on the OneDrive website) before resetting or handing over the device.

## Restore

Close the app first. Then either extract the ZIP into your user profile folder (`C:\Users\<name>`) and replace existing files, or run:

```powershell
.\Backup-Cursor.ps1 -Restore -ZipPath "<path to the ZIP>"
.\Backup-Cursor.ps1 -Restore -ZipPath "<zip>" -ProfilePath C:\Temp\x   # test restore into another folder
```

What restore does:

- copies existing databases and settings files to `<name>.pre-restore`
- moves leftover `-wal`/`-shm` files aside
- extracts the ZIP

Paths aren't rewritten. Chats show up only for projects opened from the same folder path as before, because all three apps link chats to the folder path. Every ZIP has restore steps in `_backup-info\README-RESTORE.txt`, and the extension list to reinstall in `_backup-info\extensions-*.txt`.

## Files

| File | Purpose |
| --- | --- |
| `Backup-AIArtifacts.cmd` | Double-click to run all three backups. Arguments are passed to each script (`-DryRun`, `-Destination`, `-Force`) |
| `Backup-ClaudeCode.ps1` | Claude Code |
| `Backup-Cursor.ps1` | Cursor |
| `Backup-Copilot.ps1` | GitHub Copilot in VS Code (and VS Code Insiders) plus the Copilot CLI |
| `AIBackup.Common.ps1` | Shared helpers, dot-sourced by the three scripts |
| `Tests\Compare-Archivers.ps1` | Compares backup/restore time and ZIP size of 7-Zip and the built-in method |

## Parameters

All three scripts take the same parameters.

| Parameter | Meaning |
| --- | --- |
| `-DryRun` | List parts, sizes, destination and archiver; write nothing |
| `-Destination <folder>` | Where the ZIP goes. Default: `<OneDrive for work or school>\AI backup`, else `<personal OneDrive>\AI backup`, else `<Desktop>\AI backup` |
| `-Restore -ZipPath <zip>` | Restore a backup |
| `-ProfilePath <folder>` | With `-Restore`: restore into another folder (testing) |
| `-Force` | Don't wait for Cursor / VS Code to close (testing only) |
| `-Archiver Auto\|7Zip\|DotNet` | `Auto` (default) uses 7-Zip when installed, else .NET. The others force one |
| `-CompressionLevel 0-9` | 7-Zip `-mx` level. Default 1 (see test results) |

## What is backed up

| Tool | Included | Left out |
| --- | --- | --- |
| Claude Code | `%USERPROFILE%\.claude` (chats in `projects\`, memory, skills, agents, commands, plugins, plans, file history, settings, `.credentials.json`); `%USERPROFILE%\.claude.json` (+ `.backup*`); `globalStorage\anthropic.claude-code` of VS Code, VS Code Insiders and Cursor; `%APPDATA%\Claude\claude_desktop_config.json` | `.claude\cache`, `shell-snapshots`, `session-env`, `ide`, `debug`, `statsig`, `telemetry`, `*.lock` |
| Cursor | `%APPDATA%\Cursor\User`: `*.json` (settings, keybindings), `snippets`, `profiles`, `globalStorage\state.vscdb` (all chats and the Cursor sign-in), `globalStorage\storage.json`, `workspaceStorage` (links chats to project folders). `%USERPROFILE%\.cursor`: `mcp.json`, `cli-config.json`, `argv.json`, `ide_state.json`, `unified_repo_list.json`, `rules`, `skills`, `agents`, `commands`, `plans`, `projects`, `plugins`, `snapshots`, `chats` | `state.vscdb.backup`, `conversation-search.db` (rebuilt), `globalStorage\anysphere.*` (agent CLI binaries, ~1.5 GB), `History`, `.cursor\extensions`, `worktrees`, `ai-tracking`, `browser-logs`, `skills-cursor` |
| Copilot (VS Code) | Per edition (`Code`, `Code - Insiders`), under `%APPDATA%\<edition>\User`: `*.json` (settings, keybindings, `mcp.json`, `chatLanguageModels.json`), `*.code-workspace`, `prompts`, `snippets`, `mcp`, `profiles`, `globalStorage\state.vscdb`, `storage.json`, `emptyWindowChatSessions`, `github.copilot-chat` (memory, session store, agents), and `workspaceStorage\*\` `workspace.json`, `state.vscdb`, `chatSessions`, `chatEditingSessions`, `GitHub.copilot-chat`. Also `%USERPROFILE%\.copilot` (Copilot CLI config, MCP, skills, sessions) | `*.vscdb.backup`, Copilot embedding caches, `debug-logs`, `logContextRecordings`, other extensions' `globalStorage`, `History`, `sync`, `.copilot\logs`, `ide`, `pkg`, `cache` |

Not covered:

- Files inside your projects (`CLAUDE.md`, `.claude\`, `.cursor\rules`, `.github\copilot-instructions.md`, `.mcp.json`). They belong in git.
- Cursor worktrees.
- The extensions themselves. Only their list is saved.

## How it works

- **The ZIP layout mirrors the user profile.** Entries are `.claude/...`, `.cursor/...`, `AppData/Roaming/Cursor/User/...`, so restoring is extracting into `C:\Users\<name>`.
- **ZIP name:** `AI-backup-<ClaudeCode|Cursor|Copilot>-<COMPUTERNAME>-<yyyyMMdd-HHmm>.zip`.
- **Built in `%TEMP%\AI-backup` and moved at the end**, so OneDrive never uploads a half-written file. Free space is checked first.
- **7-Zip if installed, otherwise .NET `ZipArchive`:**
  - Where it looks for 7-Zip: `%ProgramFiles%\7-Zip\7z.exe`, then `%ProgramFiles(x86)%`, then the `HKLM`/`HKCU\SOFTWARE\7-Zip` registry values.
  - 7-Zip writes a normal `.zip` (`-tzip`, multi-threaded), so Explorer and the .NET code can open it.
  - If AppData is redirected outside the profile, or 7-Zip fails, the script uses the .NET method.
  - The .NET method is used rather than `Compress-Archive`, which fails on files over 2 GB in Windows PowerShell 5.1.
- **Shared read** (`FileShare.ReadWrite`, 7-Zip `-ssw`), so files other programs have open are still copied. A file that still can't be read is skipped and listed in the manifest.
- **Junctions and symbolic links are not followed.**
- **`_backup-info/` in every ZIP:**
  - `backup-manifest.json`: computer, user, profile path, app versions, archiver, compress time, file count, skipped files
  - `README-RESTORE.txt`
  - `extensions-*.txt` (`id@version`)
- **Waiting for apps to close:** Cursor and VS Code are checked every 2 seconds until they are closed, with no key press needed. This also works when an agent or a non-interactive shell runs the script.
- **Claude Code chat retention:** Claude Code deletes chats older than `cleanupPeriodDays` (default 30) at startup. The script warns if the setting in `%USERPROFILE%\.claude\settings.json` is missing or below 365, but doesn't change it.

## Testing

```powershell
.\Tests\Compare-Archivers.ps1 -Tool ClaudeCode, Cursor    # results and ZIPs in %TEMP%\AI-backup-test
```

The test runs each backup with 7-Zip `-mx1`, `-mx5`, `-mx9` and with the .NET method. It then restores every ZIP into a test folder and counts the files. Results go to `results-*.csv` and `results-*.md`. The test ZIPs contain sign-in tokens: delete `%TEMP%\AI-backup-test` afterwards.

Results on a test laptop (7-Zip 26.04, Windows PowerShell 5.1, Cursor closed, no files skipped):

| Tool | Method | Raw | ZIP | Backup | Restore |
| --- | --- | --- | --- | --- | --- |
| Claude Code | 7-Zip `-mx1` | 375 MB | 127 MB | 4.7 s | 6.8 s |
| Claude Code | 7-Zip `-mx5` | 375 MB | 122 MB | 5.6 s | 6.4 s |
| Claude Code | 7-Zip `-mx9` | 375 MB | 121 MB | 33 s | 7.1 s |
| Claude Code | .NET | 375 MB | 123 MB | 14 s | 7.5 s |
| Cursor | 7-Zip `-mx1` | 4.08 GB | 819 MB | 42 s | 25 s |
| Cursor | 7-Zip `-mx5` | 4.08 GB | 780 MB | 4 min 47 s | 22 s |
| Cursor | 7-Zip `-mx9` | 4.08 GB | 757 MB | 29 min 54 s | 22 s |
| Cursor | .NET | 4.08 GB | 796 MB | 1 min 24 s | 23 s |

The default is `-mx1`: twice as fast as .NET, with a ZIP about 3 % bigger. Higher levels are slow on Cursor because 7-Zip's ZIP mode compresses each file on one thread, and Cursor's chat database is one large file.

## Limitations

- Windows only.
- Chats come back only for projects opened from the same folder path as before.
- App data locations can change with new app versions. Run `-DryRun` to see what is found.

## License

[MIT](LICENSE)
