# PS-MultiSync-Backup 🚀

> 🇷🇺 **Russian version of this documentation is available [here](README.ru.md).**

An automation script for mirroring file storages and databases based on **PowerShell** and **Robocopy**. Designed specifically for enterprise IT infrastructure.

## ✨ Key Features
- **Multitasking:** Execute any number of backup tasks in a single run.
- **Configuration Hierarchy:** Global parameters (threads, exclusions, flags) are automatically applied to all tasks unless overridden within a specific task.
- **Smart Telegram Notifications:** Distinct status alerts (Success, Warning, Error) including the specific task name and server source.
- **Deep Diagnostics:** The script analyzes Robocopy logs for specific Win32 errors (e.g., `0x00000005` — Access Denied), even if the overall exit code suggests success.
- **Automatic Rotation:** Logs are archived into `Year/Month` folder structures, preventing working directory clutter.
- **Advanced Error Handling:**
  - The script doesn't rely solely on the Robocopy exit code (`$LASTEXITCODE`), which is a sum of bitwise flags.
  - It utilizes customizable lists: `$NonCriticalExitCodes` and `$CriticalErrorHexCodes` for precise failure criticality assessment.
  - If the exit code is considered non-critical, but **specific critical Win32 HEX codes** (like Access Denied) are found within the log file, the task status is upgraded to **"WARNING"**.

## 🛠 Requirements
- Windows OS / Windows Server.
- PowerShell 5.1 (Standard).
- Execution under a domain service account with read permissions for the target file shares.
- **Important:** Save the script and config files using **UTF-8 with BOM** encoding to ensure correct Cyrillic character handling.

## 🚀 Quick Start

1. **Clone the repository:**
   ```bash
   git clone [https://github.com/qtronixx/FileShare_Backup_Scripts.git](https://github.com/qtronixx/FileShare_Backup_Scripts.git)

  # PS-MultiSync-Backup 🚀

  PowerShell automation for mirroring file shares and backups using Robocopy. Designed for reliable, configurable, and auditable backups in enterprise environments.

  ## Key updates (recent)
  - New config options: `SendTelegram`, `ArchiveCompression`, `ArchiveKeepOriginal`, `LogLevel`.
  - `-TaskName` parameter: run only specified tasks (comma-separated). When used, specified tasks run regardless of their `Enabled` flag.
  - `Enabled` per-task: when running without `-TaskName`, only tasks with `Enabled = $true` are executed.
  - Logging: per-task logs are stored in `<LogDirectory>/<TaskName>_log/`; a main script log `sync_share_YYYY-MM-dd_HH-mm.txt` is saved in the root `LogDirectory`.
  - Rotation & archive: logs older than today are moved to `LogDirectory/Archive/yyyy/MM/...` preserving subfolder structure and then compressed to ZIP (configurable).

  ## New config options
  - `SendTelegram` (bool) — enable/disable sending Telegram notifications (default: `$true`).
  - `ArchiveCompression` (bool) — compress archived monthly folders to ZIP (default: `$true`).
  - `ArchiveKeepOriginal` (bool) — keep original archived folders after compression (default: `$false`).
  - `LogLevel` (string) — `Debug|Info|Warning|Error` (default: `Info`).

  Recommendation: keep `BOT_TOKEN` out of the repo. You can set `BOT_TOKEN = $env:SYNC_BOT_TOKEN` in `config.psd1` and supply `SYNC_BOT_TOKEN` via environment or service secrets.

  ## Behavior notes
  - If you run `.\sync_share.ps1` without arguments, the script processes only tasks with `Enabled = $true` (skips and logs disabled tasks).
  - If you run `.\sync_share.ps1 -TaskName "Name1,Name2"` the script will execute the named tasks regardless of `Enabled` value. If any requested names are not found, the script warns and either fails (if none matched) or proceeds with matched tasks, logging missing names.
  - Telegram messages can be globally suppressed by setting `SendTelegram = $false` in `config.psd1` or overridden by future CLI flags.

  ## Logs
  - Main log: `<LogDirectory>/sync_share_YYYY-MM-dd_HH-mm.txt` — contains start/end of tasks, warnings, rotation and archive actions, suppressed messages.
  - Per-task logs: `<LogDirectory>/<TaskName>_log/<LogName>_DD-MM-YYYY_HH-mm.txt`.
  - Rotation moves old logs into `Archive/yyyy/MM/<relative path>` and optionally compresses month folders into ZIP files.

  ## Quick Start

  1. Copy config example and edit:
  ```powershell
  cp config.psd1.example config.psd1
  ```

  2. Edit `config.psd1`: set `BOT_TOKEN` (or use `SYNC_BOT_TOKEN` env var), `CHAT_ID`, `LogDirectory`, tasks array.

  3. Run (examples):
  ```powershell
  # run enabled tasks only
  .\sync_share.ps1

  # run specific tasks (runs even if Enabled=$false)
  .\sync_share.ps1 -TaskName "SQL,fileshare"
  ```

  ## Config examples
  Set `BOT_TOKEN` from environment in `config.psd1`:
  ```powershell
  BOT_TOKEN = $env:SYNC_BOT_TOKEN
  ```

  Example task block:
  ```powershell
  @{
    Name = 'fileshare'
    Enabled = $true
    Source = '\\s-fs03\path\to\share'
    Destination = 'C:\\tmp\\FileShare'
    LogName = 'Bckp_FileShare'
    MultiThread = 32
  }
  ```

  ---
