#
# Файл настроек конфигурации для Robocopy Sync Script
# Используется Import-PowerShellDataFile
#

@{
    # ==================================
    # Настройки Telegram
    # ==================================
    BOT_TOKEN = "You tiken here"
    CHAT_ID = "-Chat ID"
    MESSAGE_THREAD_ID = "19" # If needed thread ID
    
# ==================================
    # Основные настройки бэкапа
    # ==================================
    LogDirectory = 'C:\Logs' # 'D:\Bckp\Logs'
    
    # Настройки источника и приемника
    SOURCE = '\\s-fs03\Файловое хранилище' # '\\s-fs03\Файловое хранилище'
    DESTINATION = 'C:\tmp' # 'D:\Bckp\File_Share'

    # Управление параметрами Robocopy
    EnableSEC  = $false   # Копировать права безопасности (/SEC)
    EnableMIR  = $true   # Зеркалирование (/MIR)
    MultiThread = 64      # Количество потоков (/MT)
    MaxRetries  = 5       # Количество попыток (/R)
    WaitTime    = 5      # Время ожидания между попытками (/W)
    
}
