# Invoke-MirrorBackup

**[English]** | [Русский](README.ru.md)

A backup / one-way mirroring script (Robocopy) with flexible error classification,
Telegram notifications, and automatic ticket registration in Naumen ITSM 365 on
critical failures. A single script serves an arbitrary number of independent tasks
(file shares, directories with DB dumps, etc.) — task settings are defined in a
separate `.psd1` config, without modifying the code.

## Features

- One-way mirroring (`/MIR`) of source to destination with multithreading (`/MT`).
- Result classification: **SUCCESS / WARNING / CRITICAL FAILURE** — not only by the
  Robocopy return code (sum of bit flags), but also by analyzing the log for HEX codes
  of critical Win32 errors (e.g., access denied), even if the final return code is
  non-critical.
- Unicode Robocopy log (`/UNILOG+`) — correctly writes Cyrillic file and path names
  regardless of the console code page.
- Telegram notifications on start, success, warning, and critical failure:
  retries, timeout, proxy, full disable via a flag (`SendTelegram = $false`).
- Naumen ITSM 365 integration: on CRITICAL FAILURE a ticket is created specifying
  the agreement, service, category, and responsible team. Deduplication by
  `sourceMesId`: a repeated failure of the same task adds a comment to the already
  open ticket instead of creating new ones. The ticket is created in the initial
  lifecycle status ("New") — the transition along the chain "in progress → resolved"
  is performed by engineers.
- `-TestServiceDesk` parameter — isolated testing of the SD loop without running
  Robocopy and without affecting production deduplication.
- Settings entirely in `.psd1` configs: common ones — in `common.psd1`, task-specific
  ones — in `tasks/*.psd1`. A task can override any common field.
- Protection against parallel runs of the same task (named Mutex per task; different
  tasks do not interfere with each other).
- Source availability and destination free space check before start.
- Automatic rotation of old logs.
- `-DryRun` mode (Robocopy `/L`) — shows the plan without changing anything.

## Repository Structure

```
.
├── Invoke-MirrorBackup.ps1   # the single production script
├── common.psd1.example       # common config template (no secrets) — committed
├── common.psd1               # real config with keys — NOT committed (.gitignore)
├── .gitignore
├── tasks/
│   ├── share01.psd1          # file share
│   ├── sql01.psd1            # directory with DB backups
│   └── _sdtest.psd1          # service task for end-to-end SD test:
│                             # unreachable source -> guaranteed critical
│                             # failure -> real ticket in SD. Do not run unnecessarily!
└── tools/
    └── sd_debug.ps1          # debug sending of a ticket to SD directly (bisection
                              # of payload when troubleshooting REST API errors)
```

## Requirements

- Windows Server / Windows with Windows PowerShell 5.1+ and Robocopy (included in the OS).
- **All `.ps1` and `.psd1` must be stored in UTF-8 with BOM** — otherwise Windows
  PowerShell 5.1 will read Cyrillic as ANSI garbage (up to script parsing errors).
  In VS Code: `"files.encoding": "utf8bom"` for PowerShell files.
- A domain/local service account with permissions: read source(s), write to
  destination(s). The scheduler job runs under its name.
- Telegram bot ([@BotFather](https://t.me/BotFather)) and chat_id of the chat/channel
  where the bot is added.
- Access key (`accessKey`) for the Naumen ITSM 365 REST API with the minimum required
  permissions (creating tickets and comments within the target agreement).

## Script Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Success: non-critical Robocopy code, no critical HEX codes in the log, no bit 8. |
| `2` | **WARNING**: some files were not copied (bit 8 — open handles/permissions) and/or HEX codes from `CriticalErrorHexCodes` were found in the log. **This is a normal result for a live file share**, not a cause for alarm: at the time of copying, some files are almost always open by users/applications (including code `0x00000005` — access denied precisely because the file is busy, not a permissions problem), and it is usually picked up by the next run. Alarm should be raised not on the mere fact of code 2, but on a **sharp increase** in the number of `Failed` in the final log table relative to the usual level for this task, or on the same files repeating night after night (a sign that the file is not "flickering" but is hung/locked permanently). |
| `1` | **CRITICAL FAILURE**: Robocopy code outside `NonCriticalExitCodes` (usually 16+) or an unhandled script exception. With SD integration enabled — a ticket. |
| `4` | Parallel run of the same task (mutex busy). Not a copy error. |

Scheduler monitoring recommendation: alarm on `1` and `4`. Code `2` is normal for a live
file share and requires no separate response; the log is worth checking only if the share
of `Failed`/`Skipped` has noticeably grown relative to the usual level for this task.

## Verifying Service Desk Integration

Before enabling `SendToServiceDesk = $true` in production, verify the loop in isolation:

```powershell
.\Invoke-MirrorBackup.ps1 -ConfigPath .\tasks\share01.psd1 -TestServiceDesk
```

The script **does not run Robocopy**, creates one test ticket with the subject `[TEST] ...`
and a unique `sourceMesId` (does not overlap with the production deduplication key), and
outputs its UUID to the console. Check in the Naumen UI: status "New", service, category,
responsible team — then close the ticket.

Full end-to-end deduplication test (create → comment on open → new after closing) — with
the `_sdtest.psd1` task:

```powershell
.\Invoke-MirrorBackup.ps1 -ConfigPath .\tasks\_sdtest.psd1   # ticket
.\Invoke-MirrorBackup.ps1 -ConfigPath .\tasks\_sdtest.psd1   # comment on it
# close the ticket in Naumen, then:
.\Invoke-MirrorBackup.ps1 -ConfigPath .\tasks\_sdtest.psd1   # new ticket
```

## Quick Start

1. Copy `Invoke-MirrorBackup.ps1`, `common.psd1.example`, and `tasks/` to the server,
   for example to `C:\Scripts`.
2. Copy `common.psd1.example` → `common.psd1`, fill in the real `BotToken`, `ChatId`,
   and (if using SD) `SdBaseUrl`/`SdAccessKey`/`SdAgreement`/`SdTeam`/`SdService`/
   `SdCategory`. Values containing `$` — only in **single** quotes.
3. Restrict access to the folder (in `common.psd1` keys are stored in plain text):
   ```powershell
   icacls "C:\Scripts" /inheritance:r /grant:r "SYSTEM:(OI)(CI)F" "BUILTIN\Administrators:(OI)(CI)F"
   ```
4. Edit/add a task in `tasks/` (see [Configuration](#configuration)).
5. Dry run:
   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\Invoke-MirrorBackup.ps1 -ConfigPath C:\Scripts\tasks\share01.psd1 -DryRun
   ```
6. In the scheduler — one task per each `.psd1`, under the service account:
   ```
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Invoke-MirrorBackup.ps1" -ConfigPath "C:\Scripts\tasks\share01.psd1"
   ```
   In the task action: Program = `powershell.exe`, arguments — as above (full paths!),
   "Run whether user is logged on or not", "Run with highest privileges",
   "Do not start a new instance".

## Configuration

Priority: **built-in values → `common.psd1` → task config (`-ConfigPath`)**.
Any common field can be selectively overridden in a task.

### common.psd1 — common to all tasks

| Field | Purpose |
|-------|---------|
| `BotToken` | Telegram bot token. |
| `ChatId` | Chat/channel ID for notifications. |
| `MessageThreadId` | Topic ID (if the chat has topics). Overridable in a task. |
| `SendTelegram` | `$false` — do not send, write messages to the task log. |
| `ProxyUrl` / `ProxyUseDefaultCredentials` | Proxy **for Telegram only**; to Naumen — directly. |
| `Threads` | Threads for `/MT:N`. |
| `NonCriticalExitCodes` | Robocopy return codes not considered critical by themselves. |
| `CriticalErrorHexCodes` | HEX codes of Win32 errors in the log (format `(0x...`)`, raising the status to WARNING. |
| `TreatCopiedFailuresAsWarning` | `$true` — bit 8 (some files not copied) yields WARNING status. |
| `LogRetentionDays` | Log retention, days. |
| `MinFreeSpaceGB` | Free space threshold on the destination for a warning. |
| `SendToServiceDesk` | `$true` — on CRITICAL FAILURE a ticket is created in Naumen ITSM 365. |
| `SdBaseUrl` | Base URL of the installation, e.g. `https://help.example.ru`. |
| `SdAccessKey` | REST API key (`accessKey`). |
| `SdAgreement` | Agreement for tickets, e.g. `'agreement$2730701'`. |
| `SdService` | Service from the agreement, e.g. `'slmService$2730909'`. Optional. |
| `SdCategory` | Service category, e.g. `'category$2729963'` (passed as the `baseCategory` attribute). Optional. |
| `SdTeam` | Responsible team, e.g. `'team$2304303'` (the `responsibleTeam` attribute). Optional. |
| `SdClientName` | Value of the `clientName` field of the created ticket. |
| `SdSourceMesIdPrefix` | Deduplication key prefix; the full key — prefix + sanitized task name. |

### tasks/*.psd1 — task-specific

| Field | Purpose |
|-------|---------|
| `TaskName` | Task name: logs, Mutex, Telegram, SD deduplication key. Required. |
| `Source` / `Destination` | Source (UNC/local) and destination. Required. |
| `LogDir` / `LogFilePrefix` | Task log folder and prefix. Required. |
| `CopyAcls` | `$true` — adds `/SEC` (NTFS permissions). For shares usually `$true`, for DB dumps — `$false`. |
| `ExcludedFiles` / `ExcludedDirs` | Patterns for `/XF` and `/XD` (a bare directory name is excluded at any depth). |
| `MessageThreadId` | Dedicated Telegram topic for the task. |
| `SendToServiceDesk`, `Sd*` | Selective per-task overrides of SD settings. |

## Naumen ITSM 365 Integration

A ticket is created **only** on CRITICAL FAILURE (including unhandled script exceptions).
Fields: `agreement`, `service` (service), `baseCategory` (category),
`responsibleTeam` (team), `shortDescr`, `descriptionRTF`, `clientName`, `sourceMesId`.
The status is **not set** on creation — the ticket is registered in the initial lifecycle
status ("New"); "In Progress"/"Resolved" are engineers' actions.

Deduplication: before creation, an open ticket is searched by `sourceMesId`
(`SdSourceMesIdPrefix` + sanitized `TaskName`). If an open one is found — a comment with
the details of the repeated failure is added; if all found are resolved/closed — a new one
is created.

## Notification Logic

| Condition | Status |
|-----------|--------|
| Return code outside `NonCriticalExitCodes` | 🚨 CRITICAL FAILURE → Telegram + SD ticket |
| Code in `NonCriticalExitCodes`, HEX from `CriticalErrorHexCodes` found | ⚠️ WARNING |
| Code in `NonCriticalExitCodes`, bit 8 and `TreatCopiedFailuresAsWarning = $true` | ⚠️ WARNING |
| Code in `NonCriticalExitCodes`, no HEX codes, no bit 8 | ✅ SUCCESS |

Robocopy return codes are a sum of bit flags: `1` — files were copied; `2` — extra files
in the destination; `4` — mismatches; `8` — some files not copied; `16` — serious error
([documentation](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/robocopy)).

On a live file share, WARNING status is normal on almost every run (some files are almost
always open by users at the time of copying), and not a signal for action. See the exit
codes table above.

## Security

- Keys in `common.psd1` are stored in plain text deliberately (NTFS permissions on the
  folder are the only protection). The value is limited: the Telegram bot writes only to
  its own chats; for `SdAccessKey` — request minimum permissions from the Naumen
  administrator.
- `common.psd1` is not committed — only `common.psd1.example`. Check before pushing:
  `git status` / `git check-ignore common.psd1`.
- Configs are parsed via `Import-PowerShellDataFile` (literals only, no code execution).

## Troubleshooting

- **"Config not found / field not set"** — the `-ConfigPath` path, the presence of
  `common.psd1` next to the script; its path is taken from `$PSScriptRoot`, computed in
  the script body (defaults in `param()` do not work with `powershell.exe -File` in PS 5.1).
- **"Source unavailable"** — UNC path and service account permissions.
- **Code 4** — the previous run of this same task is still in progress. Different tasks
  are independent.
- **Tickets multiply instead of comments** — check the `state` format in your installation
  (`resolved`/`closed` expected) and that ticket closure is completed in the UI.
- **500 when creating a ticket** — run `tools/sd_debug.ps1` (payload bisection: comment out
  the suspicious field). It is useful to make sure the category belongs to the catalog of
  the specified service.
- **Garbled text in the log/script** — the file is not in UTF-8 with BOM; re-encode it with
  an editor.
- **Ticket not found in the UI by creation time** — `registrationDate` in REST is returned
  in UTC; in the UI the time is Moscow (+3).

## Versions

- **4.4** — SD: assignment to a team (`SdTeam`), service (`SdService`), category
  (`SdCategory` → `baseCategory` attribute); creation without an explicit `state`;
  deduplication searches for an open ticket among all matches; capturing the server
  response body on REST errors.
- **4.3** — `-TestServiceDesk`; proxy for Telegram only; Naumen directly.
- **4.2** — Naumen ITSM 365 integration, deduplication by `sourceMesId`.
- **4.1** — Telegram proxy, `SendTelegram`.
- **4.0** — `common.psd1` + task configs, `TreatCopiedFailuresAsWarning`.
- **3.0** — single script for multiple tasks.
- **2.x** — settings moved to configs, Unicode log, Telegram retries, mutex.
- **1.6** — original separate scripts (share and DB).