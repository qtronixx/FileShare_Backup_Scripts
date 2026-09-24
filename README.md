# Invoke-MirrorBackup

[Читать на Русском](README.ru.md) | **[English]**

A backup / one-way mirroring script (based on Robocopy) featuring flexible
error classification, Telegram notifications, and automatic ticket creation
in Naumen ITSM 365 upon critical failures. A single script handles any
number of independent tasks (file shares, database dump directories, etc.)—
task settings are defined via a separate `.psd1` config file, requiring no code changes.

## Features

- One-way mirroring (`/MIR`) from source to destination with multi-threading (`/MT`).
- Result classification: **SUCCESS / WARNING / CRITICAL FAILURE** — based not only
on the Robocopy return code (bitmask sum) but also on log analysis for specific
Win32 critical error HEX codes (e.g., Access Denied), even if the overall return code
is not flagged as critical.
- Unicode Robocopy logging (`/UNILOG+`) — correctly writes Cyrillic filenames and paths
regardless of the console code page.
- Telegram notifications on startup, success, warning, and critical failure:
includes retry logic, timeouts, proxy support, and a flag to disable notifications entirely (`SendTelegram = $false`).
- Naumen ITSM 365 integration: upon a CRITICAL FAILURE, a ticket is created specifying
the SLA, service, category, and responsible team. Deduplication via `sourceMesId`:
a recurring failure for the same task adds a comment to the existing ticket
rather than creating duplicates. Tickets are created in the initial lifecycle status ("New");
engineers handle the transition through the "In Progress → Resolved" workflow. - `-TestServiceDesk` parameter: performs an isolated check of the Service Desk (SD) integration without running Robocopy
and without affecting production deduplication.
- Settings are defined entirely in `.psd1` config files: global settings in `common.psd1`,
task-specific settings in `tasks/*.psd1`. A task can override any global field.
- Protection against concurrent execution of the same task (uses a named Mutex per task;
different tasks do not interfere with each other).
- Checks source availability and free space on the destination before starting.
- Automatic rotation of old logs.
- `-DryRun` mode (Robocopy `/L`): displays the execution plan without making any changes.

## Repository Structure

```
.
├── Invoke-MirrorBackup.ps1   # the only production script
├── common.psd1.example       # global config template (no secrets) — committed to repo
├── common.psd1               # actual config with keys — NOT committed (.gitignore)
├── .gitignore
├── tasks/
│   ├── share01.psd1          # file share
│   ├── sql01.psd1            # directory with DB backups
│   └── _sdtest.psd1          # service task for end-to-end SD testing:
│                             # unreachable source -> guaranteed critical
│                             # failure -> real SD ticket. Do not run unnecessarily!
└── tools/
└── sd_debug.ps1          # debug script to send a ticket directly to SD (payload
# bisection for REST API error troubleshooting)
```

## Requirements

- Windows Server / Windows with Windows PowerShell 5.1+ and Robocopy (included with the OS). - **Store all `.ps1` and `.psd1` files using UTF-8 with BOM encoding** — otherwise, Windows PowerShell
5.1 will interpret Cyrillic characters as ANSI garbage (potentially causing script parsing errors). 
In VS Code: use `"files.encoding": "utf8bom"` for PowerShell files.
- A domain or local service account with permissions to read the source(s) and write
to the destination(s). The scheduler task runs under this account.
- A Telegram bot ([@BotFather](https://t.me/BotFather)) and the `chat_id` of the chat or channel
where the bot has been added.
- A Naumen ITSM 365 REST API access key (`accessKey`) with the minimum required permissions
(creating tickets and comments within the scope of the target agreement).

## Script exit codes

| Code | Meaning |
|-----|----------|
| `0` | Success: non-critical Robocopy code; no critical HEX codes in the log; bit 8 not set. |
| `2` | **WARNING**: Some files were not copied (bit 8 — open handles/permissions) and/or HEX codes from `CriticalErrorHexCodes` were found in the log. **This is a normal outcome for an active file share**, not a cause for alarm: at the time of copying, some files are almost always open by users or applications (including code `0x00000005` — "Access Denied" specifically due to the file being in use, rather than a permissions issue), and these are usually picked up in the next run. You should be concerned not by the mere occurrence of code 2, but by a **sharp increase** in the number of `Failed` entries in the log summary compared to the task's usual baseline, or by the same files failing night after night (indicating that the file isn't just "flickering" but is permanently stuck or locked). |
| `1` | **CRITICAL FAILURE**: Robocopy code outside `NonCriticalExitCodes` (usually 16+) or an unhandled script exception. If SD integration is enabled, a ticket is created. |
| `4` | Concurrent execution of the same task (mutex is locked). Not a copying error. |

Scheduler monitoring recommendation: trigger an alert on codes `1` and `4`; `2` — "view log".

## Verifying Service Desk Integration

Before enabling `SendToServiceDesk = $true` for production, test the setup in isolation:

```powershell
.\Invoke-MirrorBackup.ps1 -ConfigPath .\tasks\share01.psd1 -TestServiceDesk
```

The script **does not run Robocopy**; instead, it creates a single test ticket with the subject `[TEST] ...` and
a unique `sourceMesId` (distinct from the production deduplication key), then outputs its
UUID to the console. Check the Naumen UI for the status "New," service, category, and responsible
team—then close the ticket.

Perform a full end-to-end deduplication test (creation → comment on open ticket → new ticket after
closure) using the `_sdtest.psd1` task:

```powershell
.\Invoke-MirrorBackup.ps1 -ConfigPath .\tasks\_sdtest.psd1   # ticket creation
.\Invoke-MirrorBackup.ps1 -ConfigPath .\tasks\_sdtest.psd1   # comment on the ticket
# close the ticket in Naumen, then:
.\Invoke-MirrorBackup.ps1 -ConfigPath .\tasks\_sdtest.psd1   # new ticket
```

## Quick Start

1. Copy `Invoke-MirrorBackup.ps1`, `common.psd1.example`, and the `tasks/` folder to the server,
for example, to `C:\Scripts`.
2. Copy `common.psd1.example` to `common.psd1` and enter the actual values ​​for `BotToken`,
`ChatId`, and (if using SD) `SdBaseUrl`/`SdAccessKey`/`SdAgreement`/`SdTeam`/
`SdService`/`SdCategory`. Values ​​containing `$` must be enclosed in **single** quotes. 3. Restrict access to the folder (keys in `common.psd1` are stored in plain text):
```powershell
icacls "C:\Scripts" /inheritance:r /grant:r "SYSTEM:(OI)(CI)F" "BUILTIN\Administrators:(OI)(CI)F"
```
4. Edit/add a task in `tasks/` (see [Configuration](#configuration)).
5. Dry run:
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\Invoke-MirrorBackup.ps1 -ConfigPath C:\Scripts\tasks\share01.psd1 -DryRun
```
6. Add to Task Scheduler — one task per `.psd1` file, running under a service account:
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Invoke-MirrorBackup.ps1" -ConfigPath "C:\Scripts\tasks\share01.psd1"
```
Task action: Program = `powershell.exe`, arguments as above (use full paths!),
"Run whether user is logged on or not", "Run with highest privileges",
"Do not start a new instance".

## Configuration

Priority: **built-in values ​​→ `common.psd1` → task config (`-ConfigPath`)**.
Any common field can be specifically overridden within a task.

### common.psd1 — shared by all tasks

| Field | Purpose |
|------|------------|
| `BotToken` | Telegram bot token. |
| `ChatId` | Chat/channel ID for notifications. |
| `MessageThreadId` | Topic ID (if using a chat with topics). Overridable in the task. |
| `SendTelegram` | `$false` — do not send; write messages to the task log instead. |
| `ProxyUrl` / `ProxyUseDefaultCredentials` | Proxy **for Telegram only**; direct connection to Naumen. |
| `Threads` | Threads for `/MT:N`. |
| `NonCriticalExitCodes` | Robocopy exit codes not considered critical in themselves. |
| `CriticalErrorHexCodes` | Win32 error HEX codes in the log (format `(0x...)`) that raise the status to WARNING. |
| `TreatCopiedFailuresAsWarning` | `$true` — bit 8 (some files not copied) results in a WARNING status. |
| `LogRetentionDays` | Log retention period (in days). |
| `MinFreeSpaceGB` | Free space threshold on the destination for issuing a warning. |
| `SendToServiceDesk` | `$true` — a ticket is created in Naumen ITSM 365 upon a CRITICAL FAILURE. |
| `SdBaseUrl` | Base URL of the installation, e.g., `https://help.example.ru`. |
| `SdAccessKey` | REST API key (`accessKey`). |
| `SdAgreement` | Agreement for tickets, e.g., `'agreement$2730701'`. |
| `SdService` | Service from the agreement, e.g., `'slmService$2730909'`. Optional. |
| `SdCategory` | Service category, e.g., `'category$2729963'` (passed as the `baseCategory` attribute). Optional. |
| `SdTeam` | Responsible team, e.g., `'team$2304303'` (`responsibleTeam` attribute). Optional. |
| `SdClientName` | Value for the `clientName` field of the created ticket. |
| `SdSourceMesIdPrefix` | Deduplication key prefix; the full key is the prefix + the sanitized task name. |

### tasks/*.psd1 — task-specific

| Field | Purpose |
|------|------------|
| `TaskName` | Task name: used for logs, Mutex, Telegram, and SD deduplication key. Mandatory. |
| `Source` / `Destination` | Source (UNC/local path) and destination. Mandatory. |
| `LogDir` / `LogFilePrefix` | Task log folder and prefix. Mandatory. |
| `CopyAcls` | `$true` — adds `/SEC` (NTFS permissions). Usually `$true` for shares, `$false` for database dumps. |
| `ExcludedFiles` / `ExcludedDirs` | Patterns for `/XF` and `/XD` (bare directory name excluded at any depth). |
| `MessageThreadId` | Dedicated Telegram topic for the task. |
| `SendToServiceDesk`, `Sd*` | Task-specific overrides for SD settings. |

## Integration with Naumen ITSM 365

A ticket is created **only** upon a CRITICAL FAILURE (including unhandled script
exceptions). Fields: `agreement`, `service`, `baseCategory`,
`responsibleTeam`, `shortDescr`, `descriptionRTF`, `clientName`, `sourceMesId`.
The status is **not set** upon creation; the ticket is registered with the initial
lifecycle status ("New"); "In Progress"/"Resolved" are actions performed by engineers.

Deduplication: before creation, the system searches for an open ticket using `sourceMesId`
(`SdSourceMesIdPrefix` + sanitized `TaskName`). If an open ticket is found, a comment
with details of the recurring failure is added; if only resolved/closed tickets are found,
a new ticket is created.

## Notification Logic

| Condition | Status |
|---------|--------|
| Return code outside `NonCriticalExitCodes` | 🚨 CRITICAL FAILURE → Telegram + SD ticket |
| Code in `NonCriticalExitCodes`, HEX code from `CriticalErrorHexCodes` found | ⚠️ WARNING |
| Code in `NonCriticalExitCodes`, bit 8 set and `TreatCopiedFailuresAsWarning = $true` | ⚠️ WARNING |
| Code in `NonCriticalExitCodes`, no HEX codes, bit 8 not set | ✅ SUCCESS |

Robocopy return codes are the sum of bit flags: `1` — files were copied; `2` — extra
files in the destination; `4` — mismatches; `8` — some files were not copied; `16` —
serious error ([documentation](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/robocopy)). ## Security

- Keys in `common.psd1` are stored in plain text by design (NTFS folder permissions are the
only protection). The risk is limited: the Telegram bot writes only to its own chats; 
for `SdAccessKey`, request minimum necessary permissions from the Naumen administrator.
- `common.psd1` is not committed to the repository—only `common.psd1.example` is. Check
before pushing: `git status` / `git check-ignore common.psd1`.
- Configs are parsed via `Import-PowerShellDataFile` (literals only; no code execution).

## Troubleshooting

- **"Configuration not found / field not set"** — check the `-ConfigPath` and the presence
of `common.psd1` next to the script; the path is derived from `$PSScriptRoot`, calculated
within the script body (default values ​​in `param()` do not work with `powershell.exe -File` in PS 5.1).
- **"Source unavailable"** — check the UNC path and service account permissions.
- **Code 4** — a previous run of the same task is still in progress. Different tasks are independent.
- **Tickets created instead of comments** — check the `state` format in your installation
(expects `resolved`/`closed`) and ensure ticket closure is fully completed in the UI.
- **500 error when creating a ticket** — run `tools/sd_debug.ps1` (payload bisection:
comment out the suspicious field). It is useful to verify that the category belongs
to the catalog of the specific service indicated.
- **Garbled text (mojibake) in log/script** — the file is not encoded as UTF-8 with BOM; 
convert the encoding using your editor.
- **Ticket not found in UI by creation time** — `registrationDate` in the REST API is
returned in UTC, whereas the UI displays Moscow time (+3). ## Versions

- **4.4** — SD: assignment to team (`SdTeam`), service (`SdService`), category (`SdCategory` → `baseCategory` attribute); creation without an explicit `state`; deduplication searches for an open ticket among all matches; capture of server response body on REST errors.
- **4.3** — `-TestServiceDesk`; proxy for Telegram only; direct Naumen integration.
- **4.2** — Naumen ITSM 365 integration, deduplication by `sourceMesId`.
- **4.1** — Telegram proxy, `SendTelegram`.
- **4.0** — `common.psd1` + task configs, `TreatCopiedFailuresAsWarning`.
- **3.0** — single script for multiple tasks.
- **2.x** — settings moved to config files, Unicode log, Telegram retries, mutex.
- **1.6** — original separate scripts (shared folder and DB).