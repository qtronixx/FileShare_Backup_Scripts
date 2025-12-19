<#
.SYNOPSIS
  Многозадачный скрипт зеркалирования на базе Robocopy с иерархией настроек и уведомлениями в Telegram.
  передача параметра из командной строки, для выполнения конкретной задачи из массива Tasks.
.NOTES
  Версия: 1.1.0 (dev) (Multi-Task Inheritance)
  Автор: Qtronix (Dmitry V Orlov)
#>

param(
        [string]$TaskName
)

# =====================================================================
# ИМПОРТ НАСТРОЕК
# =====================================================================
$ConfigFilePath = Join-Path (Split-Path $MyInvocation.MyCommand.Path) "config.psd1"

if (-not (Test-Path $ConfigFilePath)) {
    Write-Error "Критическая ошибка: Файл конфигурации $ConfigFilePath не найден!"
    exit 1
}

$Config = Import-PowerShellDataFile -Path $ConfigFilePath

# -----------------------------
# Проверка/нормализация конфигурации
# -----------------------------
# Приведём некоторые значения к ожидаемому виду и проверим обязательные поля позже (лог будет создан ниже)
if ($null -eq $Config) {
    Write-Error "Критическая ошибка: не удалось загрузить конфигурацию из $ConfigFilePath"
    exit 1
}

# =====================================================================
# ИНИЦИАЛИЗАЦИЯ ПЕРЕМЕННЫХ
# =====================================================================
$TelegramAPI = "https://api.telegram.org/bot$($Config.BOT_TOKEN)/sendMessage"
$LogDir = $Config.LogDirectory
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -Type Directory | Out-Null }

# Главный лог скрипта в корне $LogDir
$MainLogFile = Join-Path $LogDir "sync_share_$((Get-Date).ToString('dd-MM-yyyy_HH-mm')).txt"
"$(Get-Date -Format G) [ИНФО] --- START sync_share ---" | Out-File -FilePath $MainLogFile -Encoding UTF8 -Append

# -----------------------------
# Конфигурационная валидация и приведение значений
# -----------------------------
# Поддержка переменной окружения для токена (если задана)
if ($env:SYNC_BOT_TOKEN) {
    $Config.BOT_TOKEN = $env:SYNC_BOT_TOKEN
    $TelegramAPI = "https://api.telegram.org/bot$($Config.BOT_TOKEN)/sendMessage"
    "$(Get-Date -Format G) [ИНФО] BOT_TOKEN взят из переменной окружения SYNC_BOT_TOKEN" | Out-File -FilePath $MainLogFile -Encoding UTF8 -Append
}

# Проверяем наличие основных полей
if (-not $Config.Tasks -or $Config.Tasks.Count -eq 0) {
    "$(Get-Date -Format G) [ОШИБКА] В конфигурации отсутствуют задачи (Tasks)" | Out-File -FilePath $MainLogFile -Encoding UTF8 -Append
    Write-Error "В конфигурации отсутствуют задачи (Tasks)"
    exit 1
}

# Проверка уникальности Name и LogName
$names = $Config.Tasks | ForEach-Object { $_.Name }
$lognames = $Config.Tasks | ForEach-Object { $_.LogName }
if ($names.Count -ne ($names | Select-Object -Unique).Count) {
    "$(Get-Date -Format G) [ОШИБКА] Обнаружены дублирующиеся значения Task.Name в конфиге" | Out-File -FilePath $MainLogFile -Encoding UTF8 -Append
    Write-Error 'Duplicate task Name values found in config.Tasks'
    exit 1
}
if ($lognames.Count -ne ($lognames | Select-Object -Unique).Count) {
    "$(Get-Date -Format G) [ОШИБКА] Обнаружены дублирующиеся значения Task.LogName в конфиге" | Out-File -FilePath $MainLogFile -Encoding UTF8 -Append
    Write-Error 'Duplicate task LogName values found in config.Tasks'
    exit 1
}

# Ensure LogDirectory exists and is writable
try {
    if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }
    "$([System.IO.Path]::GetFullPath($LogDir))" | Out-Null
}
catch {
    "$(Get-Date -Format G) [ОШИБКА] Невозможно создать/доступ к LogDirectory: $LogDir : $_" | Out-File -FilePath $MainLogFile -Encoding UTF8 -Append
    Write-Error "Cannot access LogDirectory: $LogDir"
    exit 1
}

# Приведение глобальных числовых настроек и ограничения
if (-not $Config.MultiThread) { $Config.MultiThread = 8 }
$Config.MultiThread = [int]$Config.MultiThread
if ($Config.MultiThread -lt 1) { $Config.MultiThread = 1 }
if ($Config.MultiThread -gt 128) { $Config.MultiThread = 128 }

if (-not $Config.MaxRetries) { $Config.MaxRetries = 5 }
$Config.MaxRetries = [int]$Config.MaxRetries
if ($Config.MaxRetries -lt 0) { $Config.MaxRetries = 0 }

if (-not $Config.WaitTime) { $Config.WaitTime = 5 }
$Config.WaitTime = [int]$Config.WaitTime
if ($Config.WaitTime -lt 0) { $Config.WaitTime = 0 }

# Установим значения по умолчанию для опциональных флагов, если они отсутствуют
if ($null -eq $Config.ArchiveCompression) { $Config.ArchiveCompression = $true }
if ($null -eq $Config.ArchiveKeepOriginal) { $Config.ArchiveKeepOriginal = $false }
if (-not $Config.LogLevel) { $Config.LogLevel = 'Info' }

# Флаг включения отправки уведомлений (по-умолчанию true)
if ($null -eq $Config.SendTelegram) { $Config.SendTelegram = $true }
$SendTelegram = [bool]$Config.SendTelegram

# Нормализуем задачи: проверим обязательные поля и подставим defaults
foreach ($t in $Config.Tasks) {
    if (-not $t.Name -or -not $t.Source -or -not $t.Destination -or -not $t.LogName) {
        "$(Get-Date -Format G) [ОШИБКА] Неверный блок задачи (отсутствует Name/Source/Destination/LogName): $($t | Out-String)" | Out-File -FilePath $MainLogFile -Encoding UTF8 -Append
        Write-Error "Task missing required fields (Name/Source/Destination/LogName)"
        exit 1
    }
    if ($null -eq $t.Enabled) { $t.Enabled = $true }
    if (-not $t.MultiThread) { $t.MultiThread = $Config.MultiThread }
    if (-not $t.MaxRetries) { $t.MaxRetries = $Config.MaxRetries }
    if (-not $t.WaitTime) { $t.WaitTime = $Config.WaitTime }
    # приведение типов
    $t.MultiThread = [int]$t.MultiThread
    if ($t.MultiThread -lt 1) { $t.MultiThread = 1 }
    if ($t.MultiThread -gt 128) { $t.MultiThread = 128 }
}

$NonCriticalExitCodes = @(0,1,2,3,4,5,6,7,8,9,10,11)

# =====================================================================
# ФУНКЦИИ
# =====================================================================

# Функция для выбора параметра (Приоритет: Задача -> Глобальные настройки)
function Get-TaskParam {
    param($TaskValue, $GlobalValue)
    if ($null -ne $TaskValue) { return $TaskValue }
    return $GlobalValue
}

# Функция отправки уведомления
Function Send-TelegramNotification {
    Param ( [string]$Message )
    if (-not $SendTelegram) {
        # Telegram отключён — логируем в главный лог и не выполняем HTTP-запрос
        "$(Get-Date -Format G) [INFO] Telegram disabled; message suppressed: $Message" | Out-File -FilePath $MainLogFile -Encoding UTF8 -Append
        return
    }
    $Params = @{
        chat_id = $Config.CHAT_ID
        text = $Message
        message_thread_id = $Config.MESSAGE_THREAD_ID 
    }
    try { 
        Invoke-RestMethod -Uri $TelegramAPI -Method Post -Body $Params | Out-Null 
    }
    catch { 
        Write-Host "Ошибка отправки в Telegram: $_" 
        # Если LogFile уже определен в цикле, пишем ошибку туда
        if ($LogFile) {
            "$(Get-Date -Format G) [ОШИБКА TELEGRAM] $($_.ToString())" | Out-File -FilePath $LogFile -Encoding UTF8 -Append
        } elseif ($MainLogFile) {
            "$(Get-Date -Format G) [ОШИБКА TELEGRAM] $($_.ToString())" | Out-File -FilePath $MainLogFile -Encoding UTF8 -Append
        }
    }
}

# =====================================================================
# 📂 РОТАЦИЯ И АРХИВИРОВАНИЕ ЛОГОВ
# Рекурсивно переносим старые .txt в Archive/yyyy/MM, сохраняя структуру подпапок
# =====================================================================
Write-Host "$(Get-Date -Format G) [ИНФО] --- ЗАПУСК РОТАЦИИ ЛОГОВ ---"

$ArchiveRoot = Join-Path -Path $LogDir -ChildPath "Archive"
$Today = (Get-Date).Date 
if (-not (Test-Path $ArchiveRoot)) { New-Item -Path $ArchiveRoot -Type Directory | Out-Null }

# Находим все логи (включая в подпапках), но исключаем уже архивные
$OldLogs = Get-ChildItem -Path $LogDir -Filter "*.txt" -Recurse -File | Where-Object { $_.LastWriteTime -lt $Today -and ($_.FullName -notlike (Join-Path $ArchiveRoot '*')) }
# Массив для хранения уникальных месячных папок, в которые перемещались логи
$ArchivedMonthDirs = @()
if ($OldLogs) {
    foreach ($Log in $OldLogs) {
        # относительный путь файла относительно $LogDir (включая подпапки и имя файла)
        $relativePath = $Log.FullName.Substring($LogDir.Length).TrimStart('\','/')
        $monthSub = $Log.LastWriteTime.ToString("yyyy\\MM")
        $destFullPath = Join-Path $ArchiveRoot (Join-Path $monthSub $relativePath)
        $destDir = Split-Path $destFullPath -Parent
        if (-not (Test-Path $destDir)) { New-Item -Path $destDir -ItemType Directory -Force | Out-Null }
        Move-Item -Path $Log.FullName -Destination $destFullPath -Force
        # добавить месячную папку в список для последующей архивации
        $monthDirPath = Join-Path $ArchiveRoot $monthSub
        if (-not ($ArchivedMonthDirs -contains $monthDirPath)) { $ArchivedMonthDirs += $monthDirPath }
        "$(Get-Date -Format G) [ИНФО] Перемещён лог: $($Log.FullName) -> $destFullPath" | Out-File -FilePath $MainLogFile -Encoding UTF8 -Append
    }

    # Сжимаем по-месяцам и удаляем исходные папки после успешного архива
    foreach ($monthDir in $ArchivedMonthDirs) {
        if (-not (Test-Path $monthDir)) { continue }
        $zipPath = "$monthDir.zip"
        if (Test-Path $zipPath) {
            # если уже есть zip с таким именем, создаём уникальное имя
            $zipPath = "$monthDir_$((Get-Date).ToString('yyyyMMdd_HHmmss')).zip"
        }
        try {
            Compress-Archive -Path (Join-Path $monthDir '*') -DestinationPath $zipPath -Force
            "$(Get-Date -Format G) [ИНФО] Упаковано: $monthDir -> $zipPath" | Out-File -FilePath $MainLogFile -Encoding UTF8 -Append
            # После успешного создания архива удаляем исходную папку с файлами
            Remove-Item -Path $monthDir -Recurse -Force
            "$(Get-Date -Format G) [ИНФО] Удалена исходная папка после архивации: $monthDir" | Out-File -FilePath $MainLogFile -Encoding UTF8 -Append
        }
        catch {
            "$(Get-Date -Format G) [ОШИБКА] Ошибка при архивации ${monthDir}: $($_.ToString())" | Out-File -FilePath $MainLogFile -Encoding UTF8 -Append
        }
    }
}

# =====================================================================
# --- ОСНОВНОЙ ЦИКЛ ОБРАБОТКИ ЗАДАЧ ---
# =====================================================================

# Если передан параметр -TaskName, разбираем список целевых имён
if ($TaskName) {
    $RequestedTaskNames = $TaskName -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    Write-Host "$(Get-Date -Format G) [INFO] Выполняю только задачи: $($RequestedTaskNames -join ', ')"
} else {
    $RequestedTaskNames = $null
}

# Сформируем список задач для обработки и проверим совпадения
if ($RequestedTaskNames) {
    $MatchedTasks = @()
    $MatchedNames = @()
    foreach ($n in $RequestedTaskNames) {
        $m = $Config.Tasks | Where-Object { $_.Name -ieq $n }
        if ($m) {
            $MatchedTasks += $m
            $MatchedNames += $m.Name
        }
    }
    $Missing = $RequestedTaskNames | Where-Object { $MatchedNames -notcontains $_ }
    if ($Missing.Count -gt 0) {
        # Если не найдено ни одной задачи — критическая ошибка
        if ($MatchedTasks.Count -eq 0) {
            Write-Error "Критическая ошибка: следующие запрошенные задачи не найдены: $($Missing -join ', ')"
            $Available = $Config.Tasks | ForEach-Object { $_.Name }
            Write-Host "Доступные задачи: $($Available -join ', ')"
            "$(Get-Date -Format G) [ОШИБКА] Запрошенные задачи не найдены: $($Missing -join ', ')" | Out-File -FilePath $MainLogFile -Encoding UTF8 -Append
            exit 2
        }

        # Частичные совпадения — предупреждение, записываем в главный лог и продолжаем с найденными задачами
        $warnMsg = "Предупреждение: некоторые запрошенные задачи не найдены и будут пропущены: $($Missing -join ', ')"
        Write-Warning $warnMsg
        "$(Get-Date -Format G) [ПРЕДУПРЕЖДЕНИЕ] $warnMsg" | Out-File -FilePath $MainLogFile -Encoding UTF8 -Append
    }
    $TasksToProcess = $MatchedTasks
} else {
    # При запуске без параметра выполняем только включённые задачи
    $EnabledTasks = $Config.Tasks | Where-Object { $_.Enabled -ne $false }
    $DisabledTasks = $Config.Tasks | Where-Object { $_.Enabled -eq $false }
    if ($DisabledTasks.Count -gt 0) {
        $names = $DisabledTasks | ForEach-Object { $_.Name }
        "$(Get-Date -Format G) [INFO] Пропускаются отключённые задачи (Enabled = `$false): $($names -join ', ')" | Out-File -FilePath $MainLogFile -Encoding UTF8 -Append
        Write-Host "$(Get-Date -Format G) [INFO] Пропускаются отключённые задачи: $($names -join ', ')"
    }
    $TasksToProcess = $EnabledTasks
}

foreach ($Task in $TasksToProcess) {
    $TaskStartTime = Get-Date
    # Логи каждой задачи в подпапке с именем задачи + суффикс _log
    $TaskLogDir = Join-Path $LogDir ("$($Task.Name)_log")
    if (-not (Test-Path $TaskLogDir)) { New-Item -Path $TaskLogDir -Type Directory | Out-Null }
    $LogFile = Join-Path $TaskLogDir "$($Task.LogName)_$($TaskStartTime.ToString('dd-MM-yyyy_HH-mm')).txt"
    # Запись старта задачи в главный лог
    "$(Get-Date -Format G) [START TASK] $($Task.Name) Log: $LogFile" | Out-File -FilePath $MainLogFile -Encoding UTF8 -Append

    # 1. Сбор параметров (Наследование)
    $currentSEC = Get-TaskParam $Task.EnableSEC $Config.EnableSEC
    $currentMIR = Get-TaskParam $Task.EnableMIR $Config.EnableMIR
    $currentMT  = Get-TaskParam $Task.MultiThread $Config.MultiThread
    $currentR   = Get-TaskParam $Task.MaxRetries $Config.MaxRetries
    $currentW   = Get-TaskParam $Task.WaitTime $Config.WaitTime
    $currentXF  = Get-TaskParam $Task.ExcludedFiles $Config.GlobalExcludedFiles
    $currentXD  = Get-TaskParam $Task.ExcludedDirs $Config.GlobalExcludedDirs

    "--- ЗАПУСК ЗАДАЧИ: $($Task.Name) ---" | Out-File $LogFile -Encoding UTF8 -Append
    "Источник: $($Task.Source)" | Out-File $LogFile -Encoding UTF8 -Append

    # 2. Уведомление
    Send-TelegramNotification "▶️ **СТАРТ: $($Task.Name)**`n🖥 Сервер: $env:COMPUTERNAME`n📂 Из: $($Task.Source)"

    # 3. Формирование Robocopy Params
    $RoboParams = @($Task.Source, $Task.Destination, "/NP", "/XA:SH", "/XJ", "/NFL", "/NDL", "/NS")
    if ($currentMIR) { $RoboParams += "/MIR" }
    if ($currentSEC) { $RoboParams += "/SEC" }
    $RoboParams += "/MT:$currentMT"
    $RoboParams += "/R:$currentR"
    $RoboParams += "/W:$currentW"
    if ($currentXF) { $RoboParams += "/XF"; $RoboParams += $currentXF }
    if ($currentXD) { $RoboParams += "/XD"; $RoboParams += $currentXD }

    # 4. Запуск
    "$(Get-Date -Format G) [ИНФО] Команда: robocopy $($RoboParams -join ' ')" | Out-File $LogFile -Encoding UTF8 -Append
    & robocopy @RoboParams 2>&1 | Out-File $LogFile -Encoding UTF8 -Append
    $ExitCode = $LASTEXITCODE

    # 5. Анализ лога
    $CriticalHexCodes = @("0x00000005", "0x00000020")
    $LogContent = Get-Content $LogFile -Raw
    $FoundErrors = @()
    foreach ($Hex in $CriticalHexCodes) {
        if ($LogContent -match [regex]::Escape("($Hex)")) { $FoundErrors += $Hex }
    }

    # 6. Итоги
    if ($ExitCode -lt 8 -and $FoundErrors.Count -eq 0) {
        Send-TelegramNotification "✅ **УСПЕХ: $($Task.Name)**`nКод: $ExitCode"
        $taskStatus = "SUCCESS"
    } elseif ($FoundErrors.Count -gt 0) {
        Send-TelegramNotification "⚠️ **ВНИМАНИЕ: $($Task.Name)**`nОшибки: $($FoundErrors -join ', ')`nКод: $ExitCode"
        $taskStatus = "WARNING: $($FoundErrors -join ', ')"
    } else {
        Send-TelegramNotification "🚨 **КРИТИЧЕСКИЙ СБОЙ: $($Task.Name)**`nКод: $ExitCode"
        $taskStatus = "CRITICAL"
    }
    # Логируем завершение в главный лог
    "$(Get-Date -Format G) [END TASK] $($Task.Name) Status: $taskStatus ExitCode: $ExitCode" | Out-File -FilePath $MainLogFile -Encoding UTF8 -Append
    "--- ЗАВЕРШЕНИЕ ЗАДАЧИ: $($Task.Name) ---`n" | Out-File $LogFile -Encoding UTF8 -Append
}