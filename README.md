# Invoke-MirrorBackup

> 🇷🇺 **Русская версия документации доступна [здесь](README.ru.md).**

Backup/one-way mirroring script (Robocopy) with flexible error classification and Telegram notifications. A single script serves an arbitrary number of independent tasks (file shares, directories with DB dumps, etc.) — task settings are defined in a separate config, without changing the code.

## Features

- One-way mirroring (`/MIR`) of a source to a destination with multithreading (`/MT`).
- Result classification: **SUCCESS / WARNING / CRITICAL FAILURE** — not only by Robocopy exit code (sum of bit flags), but also by analyzing the log for HEX codes of critical Win32 errors (for example, access denied), even if the final exit code is non-critical.
- Telegram notifications at startup, on success, warning, and critical failure, with retries and timeout in case Telegram is unavailable.
- Task settings are fully moved to `.psd1` configs: common ones (Telegram, error codes, log retention) — in `common.psd1`, task-specific ones (source/destination, exclusions) — in `tasks/*.psd1`. A task can override any common field.
- Unicode Robocopy log (`/UNILOG:`) — correctly writes Cyrillic file and path names regardless of the console code page.
- Protection against parallel execution of the same task (named Mutex per task — different tasks do not interfere with each other and can run simultaneously).
- Check of source availability and free space on the destination disk before starting.
- Automatic rotation of old logs.
- `-DryRun` mode (equivalent to `/L` in Robocopy) — shows what would be done without actual changes.

## Repository structure

```
.
├── Invoke-MirrorBackup.ps1   # the only script
├── common.psd1.example       # common config template (without secret) — committed to git
├── common.psd1               # real config with token — NOT committed (see .gitignore)
├── .gitignore
└── tasks/
    ├── share01.psd1          # example: file share
    └── sql01.psd1            # example: directory with DB backups
```

## Requirements

- Windows Server / Windows with PowerShell 5.1+ and Robocopy (included with the OS).
- Domain or local service account with permissions to read the source(s) and write to the destination(s), under which the scheduler task will run.
- Telegram bot (created via [@BotFather](https://t.me/BotFather)) and the chat_id of the channel/chat where it has been added as a member.

## Quick start

1. Copy `Invoke-MirrorBackup.ps1` and the `tasks/` folder to the server, for example to `C:\Scripts`.
2. Copy `common.psd1.example` to `common.psd1` next to the script and fill in real `BotToken` and `ChatId`.
3. Restrict access to the script folder (`common.psd1` stores the token in plain text; the only protection is NTFS permissions):
   ```powershell
   icacls "C:\Scripts" /inheritance:r /grant:r "SYSTEM:(OI)(CI)F" "BUILTIN\Administrators:(OI)(CI)F"
   ```
4. Edit (or add a new) file in `tasks/` for your task — see the [Task configuration](#configuration) section.
5. Test in dry-run mode without copying or deleting anything:
   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\Invoke-MirrorBackup.ps1 -ConfigPath C:\Scripts\tasks\share01.psd1 -DryRun
   ```
   and review the log in the folder specified in the task config's `LogDir`.
6. Remove `-DryRun` and add one task per `.psd1` to Task Scheduler:
   ```
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\Invoke-MirrorBackup.ps1 -ConfigPath C:\Scripts\tasks\share01.psd1
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\Invoke-MirrorBackup.ps1 -ConfigPath C:\Scripts\tasks\sql01.psd1
   ```
   The task must be run under the same service account with the required access permissions.

## Configuration

The final configuration is assembled in ascending priority order:
**built-in defaults → `common.psd1` → task config (`-ConfigPath`)**.
Any field from `common.psd1` can be overridden in a specific task.

### common.psd1 — common for all tasks

| Field                           | Purpose                                                                     |
|--------------------------------|-----------------------------------------------------------------------------|
| `BotToken`                     | Telegram bot token.                                                         |
| `ChatId`                       | Chat/channel ID for notifications.                                          |
| `MessageThreadId`              | Topic ID (if chat has topics). Can be overridden in a task.                |
| `Threads`                      | Value for Robocopy `/MT:N`.                                                 |
| `NonCriticalExitCodes`         | Robocopy exit codes not considered critical by themselves.                  |
| `CriticalErrorHexCodes`        | HEX codes of Win32 errors in the log (e.g., `0x00000005`) that raise the status to "WARNING" even with a non-critical exit code. |
| `TreatCopiedFailuresAsWarning` | If `$true` — the set bit `8` in the exit code (some files not copied) always gives "WARNING" status rather than a silent "SUCCESS". |
| `LogRetentionDays`             | How many days to keep old logs before auto-deletion.                        |
| `MinFreeSpaceGB`               | Free space threshold on the destination disk for a warning.                 |

### tasks/*.psd1 — task-specific

| Field            | Purpose                                                                  |
|------------------|--------------------------------------------------------------------------|
| `TaskName`       | Task name — used in logs, Mutex name, and Telegram messages. Required.   |
| `Source`         | Copy source (UNC path or local). Required.                               |
| `Destination`    | Copy destination. Required.                                              |
| `LogDir`         | Folder for this task's logs. Required.                                   |
| `LogFilePrefix`  | Log file name prefix. Required.                                          |
| `CopyAcls`       | `$true` — adds `/SEC` (preserve source NTFS permissions). For file shares usually `$true`, for DB dump directories — `$false`. |
| `ExcludedFiles`  | List of file patterns for `/XF`.                                         |
| `ExcludedDirs`   | List of directory patterns for `/XD`.                                    |
| `MessageThreadId`| (optional) separate Telegram topic for this task, if different from the common one. |

## Notification logic

| Condition                                                                                  | Status             |
|--------------------------------------------------------------------------------------------|--------------------|
| Exit code **not** in `NonCriticalExitCodes`                                                | 🚨 CRITICAL FAILURE |
| Exit code in `NonCriticalExitCodes`, but one of `CriticalErrorHexCodes` found in the log    | ⚠️ WARNING          |
| Exit code in `NonCriticalExitCodes`, bit 8 set (some files not copied), and `TreatCopiedFailuresAsWarning = $true` | ⚠️ WARNING |
| Exit code in `NonCriticalExitCodes`, no critical HEX codes found, no bit 8 (or `TreatCopiedFailuresAsWarning = $false`) | ✅ SUCCESS |

Robocopy exit codes — sum of bit flags (see [Microsoft documentation](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/robocopy)):
`0` — no files to copy; `1` — files copied; `2` — extra files/directories detected in destination; `4` — mismatches detected; `8` — some files/directories not copied; `16` — serious error, nothing copied.

## Security

- The Telegram token is stored in `common.psd1` in plain text deliberately: the token's value is limited by the bot's permissions (it can only write to chats it is already a member of), so if the server is compromised it is enough to revoke it via @BotFather and issue a new one. The only real protection is NTFS permissions on the script folder (see above).
- `common.psd1` **must not** get into git — commit only `common.psd1.example` (already covered in `.gitignore`).
- Configs are parsed via `Import-PowerShellDataFile`, which understands only literals (hash tables/strings/arrays/numbers) and cannot execute arbitrary code — unlike dot-sourcing a regular `.ps1` as a config.

## Troubleshooting

- **"Configuration file not found"** — check the path in `-ConfigPath` and the presence of `common.psd1` next to the script (or pass `-CommonConfigPath` explicitly).
- **"Source unavailable"** — check the availability of the UNC path and the permissions of the service account under which the task runs.
- **The task immediately exits with code 2** — the previous run of the same task has not finished yet (parallel-run protection triggered). Different tasks do not affect each other.
- **Telegram notifications do not arrive** — check `BotToken`/`ChatId` in the config, whether the bot was added to the chat, and look at the task log — sending errors are logged with details of the Telegram API response.
- Cyrillic in the log looks like mojibake — this should not happen thanks to `/UNILOG:`; if it still does, open the log explicitly as `Get-Content -Encoding Unicode`.

## Versions

- **4.0** — common `common.psd1` + task configs in `tasks/`, `TreatCopiedFailuresAsWarning`.
- **3.0** — single script for multiple tasks, config per task as a whole.
- **2.x** — settings and token moved from code to config, Unicode log, Telegram retries, parallel-run protection.
- **1.6** — initial version (separate scripts for share and DB, token in code).
