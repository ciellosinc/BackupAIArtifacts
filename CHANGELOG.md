# Changelog

## v1.1.0 (2026-10-16)

First public release.

- Backs up **Claude Code**, **Cursor** and **GitHub Copilot** (VS Code, VS Code Insiders, Copilot CLI) to ZIP files in `<OneDrive>\AI backup`.
- `Backup-AIArtifacts.cmd`: one double-click runs all three backups and skips tools that aren't installed.
- Step-by-step instructions in the README that AI agents can follow from a one-line prompt.
- Uses 7-Zip (`-mx1`) when installed, else built-in .NET `ZipArchive`. Works with files over 2 GB and paths over 260 characters.
- Waits for Cursor and VS Code to close, so the chat databases are consistent. Polls instead of waiting for a key press, so it also works non-interactively.
- Builds each ZIP in `%TEMP%` and moves it into place at the end, after checking free space first.
- `-DryRun`, `-Destination`, `-Restore -ZipPath`, `-ProfilePath`, `-Archiver`, `-CompressionLevel`.
- Each ZIP has a `_backup-info` folder: manifest, restore steps, extension list.
- Warns when Claude Code's `cleanupPeriodDays` setting will delete old chats.
- `Tests\Compare-Archivers.ps1`: compares backup and restore with 7-Zip and .NET.
