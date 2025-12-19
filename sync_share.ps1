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

# =====================================================================
# ИНИЦИАЛИЗАЦИЯ ПЕРЕМЕННЫХ
# =====================================================================
$TelegramAPI = "https://api.telegram.org/bot$($Config.BOT_TOKEN)/sendMessage"
$LogDir = $Config.LogDirectory
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -Type Directory | Out-Null }

# Главный лог скрипта в корне $LogDir
$MainLogFile = Join-Path $LogDir "sync_share_$((Get-Date).ToString('dd-MM-yyyy_HH-mm')).txt"
"$(Get-Date -Format G) [ИНФО] --- START sync_share ---" | Out-File -FilePath $MainLogFile -Encoding UTF8 -Append

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
            "$(Get-Date -Format G) [ОШИБКА TELEGRAM] $_" | Out-File -FilePath $LogFile -Encoding UTF8 -Append
        } elseif ($MainLogFile) {
            "$(Get-Date -Format G) [ОШИБКА TELEGRAM] $_" | Out-File -FilePath $MainLogFile -Encoding UTF8 -Append
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
            "$(Get-Date -Format G) [ОШИБКА] Ошибка при архивации $monthDir: $_" | Out-File -FilePath $MainLogFile -Encoding UTF8 -Append
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
    $TasksToProcess = $Config.Tasks
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