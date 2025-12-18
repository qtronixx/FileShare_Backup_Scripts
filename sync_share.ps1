<#
.SYNOPSIS
  Многозадачный скрипт зеркалирования на базе Robocopy с иерархией настроек и уведомлениями в Telegram.
.NOTES
  Версия: 2.1 (Multi-Task Inheritance)
  Автор: Qtronix (Dmitry V Orlov)
#>

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
        }
    }
}

# =====================================================================
# 📂 РОТАЦИЯ И АРХИВИРОВАНИЕ ЛОГОВ
# =====================================================================
Write-Host "$(Get-Date -Format G) [ИНФО] --- ЗАПУСК РОТАЦИИ ЛОГОВ ---"

$ArchiveRoot = Join-Path -Path $LogDir -ChildPath "Archive"
$Today = (Get-Date).Date 
if (-not (Test-Path $ArchiveRoot)) { New-Item -Path $ArchiveRoot -Type Directory | Out-Null }

$OldLogs = Get-ChildItem -Path $LogDir -Filter "*.txt" -Depth 0 | Where-Object { $_.LastWriteTime -lt $Today }
if ($OldLogs) {
    foreach ($Log in $OldLogs) {
        $DestSubPath = Join-Path $ArchiveRoot $Log.LastWriteTime.ToString("yyyy\\MM")
        if (-not (Test-Path $DestSubPath)) { New-Item $DestSubPath -Type Directory -Force | Out-Null }
        Move-Item $Log.FullName -Destination $DestSubPath -Force
    }
}

# =====================================================================
# --- ОСНОВНОЙ ЦИКЛ ОБРАБОТКИ ЗАДАЧ ---
# =====================================================================

foreach ($Task in $Config.Tasks) {
    $TaskStartTime = Get-Date
    $LogFile = Join-Path $LogDir "$($Task.LogName)_$($TaskStartTime.ToString('dd-MM-yyyy_HH-mm')).txt"

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
    } elseif ($FoundErrors.Count -gt 0) {
        Send-TelegramNotification "⚠️ **ВНИМАНИЕ: $($Task.Name)**`nОшибки: $($FoundErrors -join ', ')`nКод: $ExitCode"
    } else {
        Send-TelegramNotification "🚨 **КРИТИЧЕСКИЙ СБОЙ: $($Task.Name)**`nКод: $ExitCode"
    }
    "--- ЗАВЕРШЕНИЕ ЗАДАЧИ: $($Task.Name) ---`n" | Out-File $LogFile -Encoding UTF8 -Append
}