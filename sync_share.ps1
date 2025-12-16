<#
.SYNOPSIS
  Скрипт резервного копирования и одностороннего зеркалирования сетевой файловой шары на локальный диск, использующий многопоточность и гибкую систему оповещения Telegram.
 
.DESCRIPTION
  Этот скрипт выполняет одностороннее **зеркалирование** (`/MIR`) сетевого ресурса, указанного в `$SOURCE`, на локальный диск `$DESTINATION`. Скрипт настроен на работу с резервным копированием, включая копирование прав безопасности (`/SEC`) и атрибутов (`/COPY:DATS`).

  **Оптимизация и устойчивость:**
  - **Многопоточность:** Используется `/MT:64` для ускорения синхронизации и максимальной утилизации канала.
  - **Устойчивость:** При сбоях копирования выполняются **5 повторных попыток** (`/R:5`) с интервалом в **5 секунд** (`/W:5`), чтобы преодолеть временные блокировки.
  - **Исключения:** Настроены списки для игнорирования временных, системных файлов и каталогов (`/XF`, `/XD`, `/XJ`).

  **Продвинутая обработка ошибок:**
  - Скрипт не полагается только на код завершения Robocopy (`$LASTEXITCODE`), который является суммой битовых флагов.
  - Он использует настраиваемые списки: `$NonCriticalExitCodes` и `$CriticalErrorHexCodes` для точного определения критичности сбоя.
  - Если код завершения находится в списке некритических, но в логе обнаруживаются **заданные HEX-коды критических ошибок Win32** (например, Отказано в доступе), статус задачи повышается до **"ВНИМАНИЕ"**.

  **Оповещение:** При запуске, успешном завершении, предупреждении или критическом сбое отправляется подробное уведомление в Telegram.

.PARAMETER LogFile
  Автоматически сгенерированный путь к файлу лога. Используется для записи всего вывода Robocopy, а также информации о начале, завершении и ошибках скрипта. Лог-файл необходим для анализа HEX-кодов ошибок Robocopy.
 
.NOTES
  Версия: 1.6
  Автор: Dmitry V Orlov
  Дата: 09.12.2025
  Требования: Запуск под доменной сервисной учетной записью с правами чтения всей файловой шары.
 Изменения:
    - **Добавлена ротация лог-файлов** с архивированием в папки YYYY/MM.
    - Добавлена гибкая система определения критических ошибок через $NonCriticalExitCodes.
    - Добавлен опциональный анализ лога на наличие критических паттернов ($CriticalErrorPatterns).
  
  **Параметры Robocopy в действии:**
  - `/MIR /SEC`: Зеркалирование с сохранением разрешений.
  - `/MT:64`: Многопоточность (64 потока).
  - `/R:5 /W:5`: 5 повторов, 5 секунд ожидания.
  - `/NP /XA:SH /XJ /NFL /NDL /NS`: Подавление вывода статуса и исключение служебных файлов/точек соединения.

  **Логика оповещения:**
  - **УСПЕХ:** Код возврата находится в `$NonCriticalExitCodes` И в логе **не** найдены `$CriticalErrorHexCodes`.
  - **ВНИМАНИЕ:** Код возврата находится в `$NonCriticalExitCodes`, но в логе **найдены** `$CriticalErrorHexCodes`.
  - **КРИТИЧЕСКИЙ СБОЙ:** Код возврата **не** находится в `$NonCriticalExitCodes` (обычно 16 и выше).
 
.EXAMPLE
  Get-Help .\sync_share.ps1 -Full 
  # Показать полную справку по скрипту.
  
.EXAMPLE
  .\sync_share.ps1 
  # Запустить скрипт с заданными в коде параметрами $SOURCE и $DESTINATION.

.LINK
  https://docs.microsoft.com/en-us/windows-server/administration/windows-commands/robocopy 
  # Ссылка на документацию Robocopy.
#>

# =====================================================================
# ИМПОРТ НАСТРОЕК
# =====================================================================

$ConfigFilePath = Join-Path (Split-Path $MyInvocation.MyCommand.Path) "config.psd1"

# Проверяем, существует ли файл конфигурации
if (-not (Test-Path $ConfigFilePath)) {
    Write-Error "Критическая ошибка: Файл конфигурации $ConfigFilePath не найден!"
    exit 1
}

# Импортируем все переменные в хэш-таблицу $Config
$Config = Import-PowerShellDataFile -Path $ConfigFilePath

# =====================================================================
# ИНИЦИАЛИЗАЦИЯ ПЕРЕМЕННЫХ
# =====================================================================

# Настройки Telegrama
$BOT_TOKEN = $Config.BOT_TOKEN
$CHAT_ID = $Config.CHAT_ID
$MESSAGE_THREAD_ID = $Config.MESSAGE_THREAD_ID
$TelegramAPI = "https://api.telegram.org/bot$BOT_TOKEN/sendMessage"

# Настройки логгирования
$LogDir = $Config.LogDirectory
If (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -Type Directory | Out-Null }
$LogFile = "$LogDir\DataShare_Sync_Log_$(Get-Date -Format dd-MM-yyyy_HH-mm).txt"
# 

# Настройки источника и приемника вынесены в config.psd1
$SOURCE = $Config.SOURCE
$DESTINATION = $Config.DESTINATION

# НАСТРОЙКА ИСКЛЮЧЕНИЙ: Добавляйте или удаляйте шаблоны здесь
$ExcludedFiles = @(
    "Thumbs.db",           # Кэш эскизов Windows
    "~*.*",                # Временные файлы (например, ~$Document.docx)
    "~$*",                 # Ловит ~$Document.xlsx (дополнительный шаблон!)
    "*.tmp",               # Временные файлы
    ".DS_Store",           # Служебный файл macOS
    "desktop.ini",         # Настройки папки Windows
    "*.log",               # Файлы логов (если не нужны в бэкапе)
    "*.crdownload"         # Недоскачанные файлы из браузера
)

$ExcludedDirs = @(
    "*\Cache",
    "*\Temp"
)

# Коды возврата Robocopy, которые НЕ считаются критическими ошибками.
# Robocopy возвращает сумму битовых флагов. Коды < 8 обычно не критичны.
# Код 8 (некоторые файлы не скопированы) часто включает ERROR 33, поэтому добавлен по умолчанию.
# Код 16 и выше - серьёзные ошибки.
$NonCriticalExitCodes = @(0,1,2,3,4,5,6,7,8,9,10,11) # Добавляйте или удаляйте коды здесь

# HEX-коды ошибок Windows в логе, которые считаются КРИТИЧЕСКИМИ.
# Ищем шестнадцатеричный код в скобках, например: (0x00000005)
# 0x00000005 = ERROR_ACCESS_DENIED (Отказано в доступе)
# 0x00000020 = ERROR_SHARING_VIOLATION (Файл занят другим процессом)
$CriticalErrorHexCodes = @(
    "0x00000005", # Отказ в доступе
    "0x00000020"  # Нарушение общего доступа (файл занят) не забудьте запятые
    #"0x00000021" # Нарушение блокировки (часть файла заблокирована) - обычно не критично
    # Добавляйте другие HEX-коды здесь
)

# =====================================================================
# 📂 РОТАЦИЯ И АРХИВИРОВАНИЕ ЛОГОВ
# =====================================================================

$ArchiveRoot = Join-Path -Path $LogDir -ChildPath "Archive"
$Today = (Get-Date).Date # Получаем 00:00:00 текущих суток

Write-Host "`n$(Get-Date -Format G) [ИНФО] --- ЗАПУСК РОТАЦИИ ЛОГОВ ---"

# 1. Создание корневой папки архива, если ее нет
If (-not (Test-Path $ArchiveRoot)) { 
    New-Item -Path $ArchiveRoot -Type Directory | Out-Null 
    Write-Host "$(Get-Date -Format G) [ИНФО] Создана папка архива: $ArchiveRoot"
}

# 2. Поиск логов, измененных до полуночи текущего дня
# Используем -Depth 0, чтобы не сканировать подпапки, включая Archive
$OldLogs = Get-ChildItem -Path $LogDir -Filter "*.txt" -Recurse -Depth 0 | Where-Object { 
    $_.LastWriteTime -lt $Today 
}

if ($OldLogs.Count -gt 0) {
    Write-Host "$(Get-Date -Format G) [ИНФО] Найдено $($OldLogs.Count) старых логов для архивации."
    
    # 3. Группировка логов по году и месяцу и перемещение
    $OldLogs | Group-Object { $_.LastWriteTime.ToString("yyyy\\MM") } | ForEach-Object {
        $ArchiveSubPath = Join-Path -Path $ArchiveRoot -ChildPath $_.Name
        
        # Создаем папку архива YYYY/MM, если ее нет
        If (-not (Test-Path $ArchiveSubPath)) {
            New-Item -Path $ArchiveSubPath -Type Directory -Force | Out-Null
        }
        
        # Перемещаем файлы
        $_.Group | ForEach-Object {
            Move-Item -Path $_.FullName -Destination $ArchiveSubPath -Force
        }
        Write-Host "$(Get-Date -Format G) [ИНФО] Ротация логов: Перемещено $($_.Group.Count) файлов в $ArchiveSubPath"
    }
} else {
    Write-Host "$(Get-Date -Format G) [ИНФО] Старые логи для архивации не найдены. Ротация завершена."
}
Write-Host "$(Get-Date -Format G) [ИНФО] --- РОТАЦИЯ ЛОГОВ ЗАВЕРШЕНА ---`n"

# =====================================================================
# НАСТРОЙКА ЛОГ-ФАЙЛА ДЛЯ ТЕКУЩЕГО ЗАПУСКА
# =====================================================================
# После ротации создаем новый лог-файл для текущего запуска
$LogFile = "$LogDir\DataShare_Sync_Log_$(Get-Date -Format dd-MM-yyyy_HH-mm).txt"


# =====================================================================
# ФУНКЦИЯ УВЕДОМЛЕНИЯ
# =====================================================================
Function Send-TelegramNotification {
    Param ( [Parameter(Mandatory=$true)][string]$Message )
    $Params = @{
        chat_id = $CHAT_ID
        text = $Message
        message_thread_id = $MESSAGE_THREAD_ID 
    }
    try {
        $Response = Invoke-RestMethod -Uri $TelegramAPI -Method Post -Body $Params
        "$(Get-Date -Format G) [ИНФО] Уведомление в Telegram отправлено успешно." | Out-File -FilePath $LogFile -Encoding UTF8 -Append
    }
    catch {
        $ErrorDetails = $_.Exception.Response
        "$(Get-Date -Format G) [ОШИБКА ОТПРАВКИ] Не удалось отправить сообщение в Telegram." | Out-File -FilePath $LogFile -Encoding UTF8 -Append
        "Код статуса: $($ErrorDetails.StatusCode.value__)" | Out-File -FilePath $LogFile -Encoding UTF8 -Append
        "Причина: $($ErrorDetails.StatusDescription)" | Out-File -FilePath $LogFile -Encoding UTF8 -Append
        try {
            $Reader = New-Object System.IO.StreamReader($ErrorDetails.GetResponseStream())
            $ErrorBody = $Reader.ReadToEnd()
            $Reader.Close()
            "Тело ответа Telegram: $ErrorBody" | Out-File -FilePath $LogFile -Encoding UTF8 -Append
        } catch { }
    }
}

# =====================================================================
# ЗАПУСК ROBOCOPY
# =====================================================================
"$(Get-Date -Format G) [ИНФО] Запуск Robocopy..." | Out-File -FilePath $LogFile -Encoding UTF8 -Append

# Уведомление о начале
$StartTelegramMessage = "▶️ **ЗАПУСК БЭКАПА ФАЙЛОВОЙ ШАРЫ**"
$StartTelegramMessage += "`n*Сервер:* $env:COMPUTERNAME"
$StartTelegramMessage += "`n*Начало:* $(Get-Date -Format G)"
$StartTelegramMessage += "`n*Источник:* $SOURCE"
Send-TelegramNotification -Message $StartTelegramMessage

# Запуск Robocopy с параметрами
robocopy $SOURCE $DESTINATION /MIR /SEC /MT:64 /R:5 /W:5 /NP /XA:SH /XJ /NFL /NDL /NS `
    /XF $($ExcludedFiles -join ' ') `
    2>&1 | Out-File -FilePath $LogFile -Encoding UTF8 -Append

# =====================================================================
# ПРОВЕРКА РЕЗУЛЬТАТА И ОПОВЕЩЕНИЕ (ОБНОВЛЁННАЯ ЛОГИКА С ПОИСКОМ ПО HEX-КОДАМ)
# =====================================================================

# 1. Проверка по коду возврата (основная логика)
if ($NonCriticalExitCodes -contains $LASTEXITCODE) {
    # 2. Дополнительная проверка лога на критические HEX-коды ошибок
    $LogContent = Get-Content -Path $LogFile -Raw -ErrorAction SilentlyContinue
    $FoundCriticalHexCodes = @()
    
    if ($LogContent -and $CriticalErrorHexCodes) {
        # Ищем все вхождения HEX-кодов в формате (0x........)
        $hexPattern = "\(($($CriticalErrorHexCodes -join '|'))\)"
        $errorMatches = [regex]::Matches($LogContent, $hexPattern)
        foreach ($match in $errorMatches) {
            $foundCode = $match.Groups[1].Value
            if (-not ($FoundCriticalHexCodes -contains $foundCode)) {
                $FoundCriticalHexCodes += $foundCode
            }
        }
    }

    if ($FoundCriticalHexCodes.Count -gt 0) {
        # В логе найдены критические ошибки, хотя код возврата некритический
        $WarningMessage = "⚠️ **ВНИМАНИЕ: Некритический код возврата, но в логе найдены ошибки**"
        $WarningMessage += "`n*Сервер:* $env:COMPUTERNAME"
        $WarningMessage += "`n*Код Robocopy:* $LASTEXITCODE"
        $WarningMessage += "`n*Найденные HEX-коды ошибок:* " + ($FoundCriticalHexCodes -join ", ")
        $WarningMessage += "`n*Лог-файл:* $LogFile"
        Send-TelegramNotification -Message $WarningMessage
        "$(Get-Date -Format G) [ВНИМАНИЕ] Robocopy завершён с кодом $LASTEXITCODE, но в логе обнаружены критические ошибки: $($FoundCriticalHexCodes -join ', ')." | Out-File -FilePath $LogFile -Encoding UTF8 -Append
        exit 0 # Или exit 1, если хотите считать это критическим
    } else {
        # Всё действительно в порядке
        "$(Get-Date -Format G) [УСПЕХ] Robocopy завершён без критических ошибок (Код $LASTEXITCODE)." | Out-File -FilePath $LogFile -Encoding UTF8 -Append
        # Отправляем уведомление об успешном завершении
        $SuccessTelegramMessage = "✅ **БЭКАП УСПЕШНО ЗАВЕРШЁН**"
        $SuccessTelegramMessage += "`n*Сервер:* $env:COMPUTERNAME"
        $SuccessTelegramMessage += "`n*Код Robocopy:* $LASTEXITCODE"
        $SuccessTelegramMessage += "`n*Лог-файл:* $LogFile"
        Send-TelegramNotification -Message $SuccessTelegramMessage
        exit 0
    }
} else {
    # КРИТИЧЕСКАЯ ОШИБКА (кода нет в списке некритических)
    $ErrorLogEntry = "$(Get-Date -Format G) [КРИТИЧЕСКАЯ ОШИБКА] Robocopy завершился с критическим кодом $LASTEXITCODE! Проверьте лог."
    $ErrorLogEntry | Out-File -FilePath $LogFile -Encoding UTF8 -Append
    
    $TelegramMessage = "🚨 **КРИТИЧЕСКИЙ СБОЙ БЭКАПА!**"
    $TelegramMessage += "`n*Сервер:* $env:COMPUTERNAME"
    $TelegramMessage += "`n*Задача:* Файловая Шара"
    $TelegramMessage += "`n*Код Robocopy:* $LASTEXITCODE"
    $TelegramMessage += "`n*Лог-файл:* $LogFile"
    $TelegramMessage += "`n`nСрочно проверьте доступ к $SOURCE."
    
    Send-TelegramNotification -Message $TelegramMessage
    exit 1
}