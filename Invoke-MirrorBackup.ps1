<#
.SYNOPSIS
  Единый скрипт зеркалирования (Robocopy) для нескольких задач бэкапа с уведомлениями в
  Telegram и регистрацией заявок в Naumen ITSM 365. Подробности, структура конфигов и
  история версий — в README.md / README.ru.md.

.PARAMETER ConfigPath
  Путь к .psd1-файлу конкретной задачи. Обязателен.

.PARAMETER CommonConfigPath
  Путь к общему .psd1. По умолчанию — common.psd1 рядом со скриптом.

.PARAMETER DryRun
  Запускает Robocopy с флагом /L — ничего не меняет, только показывает, что было бы сделано.

.PARAMETER TestServiceDesk
  Не выполняет Robocopy вообще. Создаёт одну тестовую заявку в Service Desk с отдельным
  sourceMesId (не пересекается с боевым ключом дедупликации задачи) и завершает работу.
  Используется для проверки SdBaseUrl/SdAccessKey/SdAgreement без риска потревожить
  реальные данные задачи или испортить историю дедупликации.

.EXAMPLE
  .\Invoke-MirrorBackup.ps1 -ConfigPath .\tasks\share01.psd1

.EXAMPLE
  .\Invoke-MirrorBackup.ps1 -ConfigPath .\tasks\sql01.psd1 -DryRun

.LINK
  https://docs.microsoft.com/en-us/windows-server/administration/windows-commands/robocopy
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [string]$CommonConfigPath = '', #(Join-Path $PSScriptRoot "common.psd1"),

    [switch]$DryRun,

    [switch]$TestServiceDesk
)

$ErrorActionPreference = 'Stop'

# На части Windows Server / PowerShell 5.1 .NET по умолчанию не включает TLS 1.2 в
# список протоколов ServicePointManager, из-за чего HTTPS-запрос к серверам, требующим
# TLS 1.2+ (в т.ч. api.telegram.org), не получает явный отказ, а зависает до таймаута.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

#region ===================== КОНФИГУРАЦИЯ =====================

# При powershell.exe -File в PS 5.1 $PSScriptRoot в дефолтах param() ещё пуст,
# поэтому путь к common.psd1 вычисляем здесь — ДО первой загрузки конфигов.
if (-not $CommonConfigPath) {
    $CommonConfigPath = Join-Path $PSScriptRoot 'common.psd1'
}

function Import-Psd1Safe {
    param([string]$Path, [string]$What)
    if (-not (Test-Path $Path)) {
        throw "$What не найден: $Path"
    }
    # Import-PowerShellDataFile парсит только литералы, без исполнения кода — безопасно
    # для конфигов, которые в перспективе может редактировать не только автор скрипта.
    Import-PowerShellDataFile -Path $Path
}

# Значения по умолчанию, если их нет ни в common.psd1, ни в конфиге задачи.
$Defaults = @{
    Threads                      = 32
    NonCriticalExitCodes         = @(0,1,2,3,4,5,6,7,8,9,10,11)
    CriticalErrorHexCodes        = @()
    TreatCopiedFailuresAsWarning = $true
    LogRetentionDays             = 30
    MinFreeSpaceGB               = 10
    ExcludedFiles                = @()
    ExcludedDirs                 = @()
    CopyAcls                     = $false
    MessageThreadId              = $null
    SendTelegram                 = $true
    ProxyUrl                     = $null
    ProxyUseDefaultCredentials   = $false

    # --- Naumen ITSM 365 ---
    SendToServiceDesk  = $false
    SdBaseUrl          = $null   # например: 'https://<tenant>.itsm365.ru'
    SdAccessKey        = $null
    SdAgreement        = $null   # например: 'agreement$2730701' — обязательно при SendToServiceDesk=$true
    SdClientName       = 'Backup Automation'
    SdSourceMesIdPrefix = 'backup_'
    SdTeam = $null
    SdService = $null
    SdCategory = $null
}

$Common = Import-Psd1Safe -Path $CommonConfigPath -What "Общий конфиг"
$Task   = Import-Psd1Safe -Path $ConfigPath        -What "Конфиг задачи"

# Слияние: Defaults -> Common -> Task (каждый следующий уровень перекрывает предыдущий).
$Config = @{}
foreach ($h in @($Defaults, $Common, $Task)) {
    foreach ($key in $h.Keys) { $Config[$key] = $h[$key] }
}

foreach ($required in @('TaskName','Source','Destination','LogDir','LogFilePrefix','BotToken','ChatId')) {
    if (-not $Config[$required]) {
        throw "В конфигурации не задано обязательное поле '$required' (проверьте $CommonConfigPath и $ConfigPath)."
    }
}

$TaskName         = $Config.TaskName
$SOURCE           = $Config.Source
$DESTINATION      = $Config.Destination
$BOT_TOKEN        = $Config.BotToken
$CHAT_ID          = $Config.ChatId
$MESSAGE_THREAD_ID = $Config.MessageThreadId
$LogDir           = $Config.LogDir
$LogFilePrefix    = $Config.LogFilePrefix
$LogRetentionDays = $Config.LogRetentionDays
$ExcludedFiles    = $Config.ExcludedFiles
$ExcludedDirs     = $Config.ExcludedDirs
$CopyAcls         = [bool]$Config.CopyAcls
$Threads          = $Config.Threads
$NonCriticalExitCodes         = $Config.NonCriticalExitCodes
$CriticalErrorHexCodes        = $Config.CriticalErrorHexCodes
$TreatCopiedFailuresAsWarning = [bool]$Config.TreatCopiedFailuresAsWarning
$MinFreeSpaceGB   = $Config.MinFreeSpaceGB
$SendTelegram     = [bool]$Config.SendTelegram
$ProxyUrl         = $Config.ProxyUrl
$ProxyUseDefaultCredentials = [bool]$Config.ProxyUseDefaultCredentials

$SendToServiceDesk   = [bool]$Config.SendToServiceDesk
$SdBaseUrl           = $Config.SdBaseUrl
$SdAccessKey         = $Config.SdAccessKey
$SdAgreement         = $Config.SdAgreement
$SdClientName        = $Config.SdClientName
$SdTeam              = $Config.SdTeam
$SdService           = $Config.SdService
$SdCategory          = $Config.SdCategory
$SdSourceMesIdPrefix = $Config.SdSourceMesIdPrefix

#endregion

#region ===================== ИНИЦИАЛИЗАЦИЯ =====================

if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }
$LogFile   = Join-Path $LogDir "$($LogFilePrefix)_$(Get-Date -Format dd-MM-yyyy_HH-mm).txt"
$StopWatch = [System.Diagnostics.Stopwatch]::StartNew()
$FinalExit = 1

function Write-Log {
    param([string]$Message, [string]$Level = "ИНФО")
    "$(Get-Date -Format G) [$Level] $Message" | Out-File -FilePath $LogFile -Append -Encoding Unicode
}

# --- Защита от параллельного запуска: имя мьютекса уникально для каждой задачи ---
$SafeTaskName = $TaskName -replace '[^a-zA-Z0-9]', '_'
$MutexName = "Global\Backup_Sync_Mutex_$SafeTaskName"
$Mutex = New-Object System.Threading.Mutex($false, $MutexName)
if (-not $Mutex.WaitOne(0)) {
    Write-Log "Обнаружен уже запущенный экземпляр задачи '$TaskName'. Завершение работы." "ПРЕДУПРЕЖДЕНИЕ"
    exit 4
}

# Стабильный ключ дедупликации заявок Service Desk: одна и та же задача — один и тот же
# sourceMesId, независимо от количества повторных сбоев подряд.
$SdSourceMesId = "$($SdSourceMesIdPrefix)$SafeTaskName"

#endregion

#region ===================== TELEGRAM =====================

function Send-TelegramNotification {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [int]$MaxAttempts = 3
    )

    if (-not $SendTelegram) {
        Write-Log "Отправка в Telegram отключена (SendTelegram = `$false). Сообщение: $Message" "ИНФО"
        return
    }

    if (-not $BOT_TOKEN) {
        Write-Log "Токен Telegram не задан (common.psd1 / $ConfigPath)." "ОШИБКА"
        return
    }

    $uri  = "https://api.telegram.org/bot$BOT_TOKEN/sendMessage"
    $body = @{
        chat_id    = $CHAT_ID
        text       = $Message
        parse_mode = "Markdown"
    }
    if ($MESSAGE_THREAD_ID) { $body.message_thread_id = $MESSAGE_THREAD_ID }

    $restParams = @{
        Uri        = $uri
        Method     = 'Post'
        Body       = $body
        TimeoutSec = 15
    }
    if ($ProxyUrl) {
        $restParams.Proxy = $ProxyUrl
        if ($ProxyUseDefaultCredentials) {
            $restParams.ProxyUseDefaultCredentials = $true
        }
    }

    for ($i = 1; $i -le $MaxAttempts; $i++) {
        try {
            Invoke-RestMethod @restParams | Out-Null
            Write-Log "Уведомление в Telegram отправлено успешно (попытка $i)."
            return
        } catch {
            Write-Log "Ошибка отправки в Telegram (попытка $i из $MaxAttempts): $($_.Exception.Message)" "ОШИБКА"
            if ($i -lt $MaxAttempts) { Start-Sleep -Seconds (3 * $i) }
        }
    }
    Write-Log "Не удалось отправить уведомление в Telegram после $MaxAttempts попыток." "ОШИБКА"
}

#endregion

#region ===================== NAUMEN ITSM 365 =====================

function Get-SdRestParams {
    # Прокси сюда сознательно не пробрасывается: ITSM 365 доступен напрямую,
    # прокси используется только для обхода блокировок Telegram.
    return @{ ContentType = 'application/json; charset=utf-8'; TimeoutSec = 20 }
}

function Find-SdIncidents {
    param([string]$SourceMesId)
    $path = "/sd/services/rest/find/serviceCall"
    try {
        $uri = "$SdBaseUrl${path}?accessKey=$SdAccessKey&attrs=UUID,state,shortDescr"
        $body = @{ sourceMesId = $SourceMesId } | ConvertTo-Json
        $restParams = Get-SdRestParams
        $resp = Invoke-RestMethod -Uri $uri -Method Post -Body $body @restParams

        # Naumen возвращает конверт { "value": [...], "Count": N }; подстраховываемся
        # и под другие варианты формы ответа.
        if     ($resp -is [System.Array]) { return @($resp) }
        elseif ($resp.value)              { return @($resp.value) }
        elseif ($resp.objects)            { return @($resp.objects) }
        elseif ($resp.UUID)               { return @($resp) }
        return @()
    } catch {
        Write-Log "Ошибка поиска заявки SD ($path): $($_.Exception.Message)" "ОШИБКА"
        return @()
    }
}

function New-SdIncident {
    param([string]$ShortDescr, [string]$DescriptionRTF, [string]$SourceMesId)
    $path = "/sd/services/rest/create-m2m/serviceCall"
    $uri = "$SdBaseUrl${path}?accessKey=$SdAccessKey&attrs=UUID"
    $payload = @{
        metaClass      = 'serviceCall$serviceCall'
        shortDescr     = $ShortDescr
        agreement      = $SdAgreement
        descriptionRTF = $DescriptionRTF
        clientName     = $SdClientName
        sourceMesId    = $SourceMesId
    }
    if ($SdTeam)    { $payload.responsibleTeam = $SdTeam }
    if ($SdService) { $payload.service = $SdService }
    if ($SdCategory) { $payload.baseCategory = $SdCategory }
    $payload = $payload | ConvertTo-Json
    $restParams = Get-SdRestParams
    $resp = Invoke-RestMethod -Uri $uri -Method Post -Body $payload @restParams
    return $resp.UUID
}

function Add-SdComment {
    param([string]$Uuid, [string]$Text)
    $path = "/sd/services/rest/create-m2m/comment"
    $uri = "$SdBaseUrl${path}?accessKey=$SdAccessKey"
    $payload = @{ source = $Uuid; text = $Text; private = $true } | ConvertTo-Json
    $restParams = Get-SdRestParams
    Invoke-RestMethod -Uri $uri -Method Post -Body $payload @restParams | Out-Null
}

function Send-ServiceDeskIncident {
    param([string]$ShortDescr, [string]$DescriptionRTF)

    if (-not $SendToServiceDesk) {
        Write-Log "Заявка в SD не создаётся: SendToServiceDesk = `$false." "ИНФО"
        return $null
    }
    if (-not $SdBaseUrl -or -not $SdAccessKey -or -not $SdAgreement) {
        Write-Log "SD-интеграция включена (SendToServiceDesk=`$true), но не заданы SdBaseUrl/SdAccessKey/SdAgreement." "ОШИБКА"
        return $null
    }

    try {
        $matches = Find-SdIncidents -SourceMesId $SdSourceMesId
        $existing = $matches | Where-Object { $_.state -notin @('resolved', 'closed') } | Select-Object -First 1

        if ($existing) {
            Write-Log "Найдена открытая заявка SD $($existing.UUID) (статус $($existing.state)) — добавляю комментарий вместо новой заявки."
            Add-SdComment -Uuid $existing.UUID -Text "Повторный критический сбой ($(Get-Date -Format G)):`n$ShortDescr"
            return $existing.UUID
        }

        $uuid = New-SdIncident -ShortDescr $ShortDescr -DescriptionRTF $DescriptionRTF -SourceMesId $SdSourceMesId
        Write-Log "Создана заявка в Service Desk: $uuid"
        return $uuid
    } catch {
        $detail = $_.Exception.Message
        $resp = $_.Exception.Response
        if ($resp) {
            try {
                $sr = New-Object IO.StreamReader($resp.GetResponseStream())
                $detail += " | Тело ответа: " + $sr.ReadToEnd()
            } catch { }
        }
        Write-Log "Ошибка создания/обновления заявки в Service Desk: $detail" "ОШИБКА"
        return $null
    }
}

#endregion

#region ===================== ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ =====================

function Remove-OldLogs {
    Get-ChildItem -Path $LogDir -Filter "$($LogFilePrefix)_*.txt" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$LogRetentionDays) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Test-Prerequisites {
    if (-not (Test-Path -Path $SOURCE)) {
        throw "Источник недоступен: $SOURCE"
    }
    $qualifier = Split-Path -Qualifier $DESTINATION -ErrorAction SilentlyContinue
    if ($qualifier) {
        $disk = Get-PSDrive -Name $qualifier.TrimEnd(':') -ErrorAction SilentlyContinue
        if ($disk) {
            $freeGB = [math]::Round($disk.Free / 1GB, 1)
            if ($freeGB -lt $MinFreeSpaceGB) {
                Write-Log "Свободного места на диске назначения мало: $freeGB ГБ." "ПРЕДУПРЕЖДЕНИЕ"
            }
        }
    }
}

#endregion

#region ===================== ОСНОВНАЯ ЛОГИКА =====================

if ($TestServiceDesk) {
    Write-Log "Тестовая проверка интеграции с Service Desk (-TestServiceDesk). Robocopy не запускается." "ИНФО"
    $TestSourceMesId = "test_$($SafeTaskName)_$(Get-Date -Format yyyyMMddHHmmss)"
    try {
        if (-not $SdBaseUrl -or -not $SdAccessKey -or -not $SdAgreement) {
            throw "Не заданы SdBaseUrl/SdAccessKey/SdAgreement (проверьте $CommonConfigPath и $ConfigPath)."
        }
        $uuid = New-SdIncident `
            -ShortDescr "[ТЕСТ] Проверка интеграции backup-скрипта — задача '$TaskName'" `
            -DescriptionRTF "Тестовая заявка от Invoke-MirrorBackup.ps1 -TestServiceDesk.`nСервер: $env:COMPUTERNAME`nВремя: $(Get-Date -Format G)`nЭту заявку можно закрыть/удалить." `
            -SourceMesId $TestSourceMesId
        Write-Log "Тестовая заявка создана успешно: $uuid" "УСПЕХ"
        Write-Host "Тестовая заявка создана: $uuid"
        Write-Host "sourceMesId: $TestSourceMesId"
        $FinalExit = 0
    } catch {
        Write-Log "Тестовая заявка НЕ создана: $($_.Exception.Message)" "ОШИБКА"
        Write-Host "Ошибка: $($_.Exception.Message)" -ForegroundColor Red
        $FinalExit = 1
    }
    $Mutex.ReleaseMutex() | Out-Null
    $Mutex.Dispose()
    exit $FinalExit
}

try {
    Write-Log "===== Запуск задачи '$TaskName' ====="
    Test-Prerequisites

    $StartMsg = "▶️ *ЗАПУСК БЭКАПА: $TaskName*`n" +
                "*Сервер:* $env:COMPUTERNAME`n" +
                "*Начало:* $(Get-Date -Format G)`n" +
                "*Источник:* $SOURCE"
    Send-TelegramNotification -Message $StartMsg

    $RobocopyArgs = @(
        $SOURCE, $DESTINATION,
        "/MIR", "/MT:$Threads", "/R:5", "/W:5",
        "/NP", "/XA:SH", "/XJ", "/NFL", "/NDL",
        "/UNILOG+:$LogFile"   # Unicode-лог — корректно пишет кириллические имена файлов
    )
    if ($CopyAcls) { $RobocopyArgs += "/SEC" }
    if ($ExcludedFiles.Count -gt 0) { $RobocopyArgs += "/XF"; $RobocopyArgs += $ExcludedFiles }
    if ($ExcludedDirs.Count  -gt 0) { $RobocopyArgs += "/XD"; $RobocopyArgs += $ExcludedDirs }
    if ($DryRun) {
        $RobocopyArgs += "/L"
        Write-Log "Режим DryRun (/L) — реальные изменения не вносятся."
    }

    Write-Log "Команда: robocopy $($RobocopyArgs -join ' ')"
    & robocopy @RobocopyArgs
    $ExitCode = $LASTEXITCODE

    $LogContent = Get-Content -Path $LogFile -Raw -Encoding Unicode -ErrorAction SilentlyContinue
    if (-not $LogContent) {
        $LogContent = Get-Content -Path $LogFile -Raw -ErrorAction SilentlyContinue
    }

    $Duration = $StopWatch.Elapsed.ToString("hh\:mm\:ss")

    # Бит 8 в коде возврата Robocopy = "некоторые файлы/каталоги не скопированы"
    # (сбои копирования были, но не обязательно фатальные — retry мог не помочь).
    $HasCopyErrors = ($ExitCode -band 8) -eq 8

    if ($NonCriticalExitCodes -contains $ExitCode) {

        $FoundHex = @()
        if ($LogContent -and $CriticalErrorHexCodes) {
            $pattern = "\(($($CriticalErrorHexCodes -join '|'))\)"
            [regex]::Matches($LogContent, $pattern) | ForEach-Object {
                $code = $_.Groups[1].Value
                if ($FoundHex -notcontains $code) { $FoundHex += $code }
            }
        }

        $IsWarning = ($FoundHex.Count -gt 0) -or ($HasCopyErrors -and $TreatCopiedFailuresAsWarning)

        if ($IsWarning) {
            $reasonParts = @()
            if ($FoundHex.Count -gt 0) { $reasonParts += "найдены HEX-коды: $($FoundHex -join ', ')" }
            if ($HasCopyErrors -and $TreatCopiedFailuresAsWarning) { $reasonParts += "код возврата указывает на несколько несокопированных файлов (бит 8)" }
            $reason = $reasonParts -join '; '

            Write-Log "Robocopy завершён с кодом $ExitCode, но обнаружены проблемы: $reason." "ВНИМАНИЕ"
            $msg = "⚠️ *ВНИМАНИЕ: обнаружены проблемы при некритическом коде возврата — $TaskName*`n" +
                   "*Сервер:* $env:COMPUTERNAME`n" +
                   "*Код Robocopy:* $ExitCode`n" +
                   "*Длительность:* $Duration`n" +
                   "*Причина:* $reason`n" +
                   "*Лог-файл:* $LogFile"
            Send-TelegramNotification -Message $msg
            $FinalExit = 2
        } else {
            Write-Log "Robocopy завершён без критических ошибок (код $ExitCode). Длительность: $Duration." "УСПЕХ"
            $msg = "✅ *БЭКАП УСПЕШНО ЗАВЕРШЁН: $TaskName*`n" +
                   "*Сервер:* $env:COMPUTERNAME`n" +
                   "*Код Robocopy:* $ExitCode`n" +
                   "*Длительность:* $Duration`n" +
                   "*Лог-файл:* $LogFile"
            Send-TelegramNotification -Message $msg
            $FinalExit = 0
        }

    } else {
        Write-Log "КРИТИЧЕСКАЯ ОШИБКА: Robocopy вернул код $ExitCode." "КРИТИЧЕСКАЯ ОШИБКА"
        $sdShortDescr = "Критический сбой бэкапа: $TaskName"
        $sdDescription = "Сервер: $env:COMPUTERNAME`nЗадача: $TaskName`nИсточник: $SOURCE`nКод Robocopy: $ExitCode`nДлительность: $Duration`nЛог-файл: $LogFile"
        $sdUuid = Send-ServiceDeskIncident -ShortDescr $sdShortDescr -DescriptionRTF $sdDescription

        $msg = "🚨 *КРИТИЧЕСКИЙ СБОЙ БЭКАПА: $TaskName*`n" +
               "*Сервер:* $env:COMPUTERNAME`n" +
               "*Код Robocopy:* $ExitCode`n" +
               "*Длительность:* $Duration`n" +
               "*Лог-файл:* $LogFile`n`n" +
               "Срочно проверьте доступ к $SOURCE."
        if ($sdUuid) { $msg += "`n*Заявка Service Desk:* $sdUuid" }
        Send-TelegramNotification -Message $msg
        $FinalExit = 1
    }

    Remove-OldLogs
}
catch {
    Write-Log "НЕОБРАБОТАННОЕ ИСКЛЮЧЕНИЕ: $($_.Exception.Message)" "КРИТИЧЕСКАЯ ОШИБКА"
    $sdUuid = Send-ServiceDeskIncident `
        -ShortDescr "Скрипт бэкапа аварийно завершился: $TaskName" `
        -DescriptionRTF "Сервер: $env:COMPUTERNAME`nЗадача: $TaskName`nОшибка: $($_.Exception.Message)`nЛог-файл: $LogFile"

    $msg = "🚨 *СКРИПТ АВАРИЙНО ЗАВЕРШИЛСЯ: $TaskName*`n" +
           "*Сервер:* $env:COMPUTERNAME`n" +
           "*Ошибка:* $($_.Exception.Message)`n" +
           "*Лог-файл:* $LogFile"
    if ($sdUuid) { $msg += "`n*Заявка Service Desk:* $sdUuid" }
    Send-TelegramNotification -Message $msg
    $FinalExit = 1
}
finally {
    $Mutex.ReleaseMutex() | Out-Null
    $Mutex.Dispose()
}

exit $FinalExit

#endregion