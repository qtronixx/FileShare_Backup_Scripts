# PS-MultiSync-Backup 🚀

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

  Configure the script:

  Rename config.psd1.example to config.psd1.

  Set your BOT_TOKEN, CHAT_ID, and MESSAGE_THREAD_ID (if applicable).

  Note: Ensure the file is saved in UTF-8 with BOM.

2. Add Tasks: Edit the Tasks array in the configuration file.

3. Setup Task Scheduler:

  Program/script: powershell.exe

  Add arguments: -ExecutionPolicy Bypass -File "C:\Path\To\sync_share.ps1"

⚙️ Settings Inheritance
If a parameter (e.g., MultiThread) is not specified within a task, it will be inherited from the global section. This allows for centralized management of settings across your entire infrastructure.

PowerShell

  Tasks = @(
      @{
          Name        = "SQL Backup"
          Source      = "\\Server\SQL_Backup"
          Destination = "D:\Backup\SQL"
          MultiThread = 8   # Overriding for this specific task only
      }
  )