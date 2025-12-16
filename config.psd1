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
    LogDirectory = "d:\Logs\Robocopy"
    
    # Настройки источника и приемника
    SOURCE = "\\s-fs03\Файловое хранилище"
    DESTINATION = "D:\Bckp\File_Share"


    # Можно также вынести массив задач SyncJobs сюда, 
    # если он редко меняется и не содержит сложных объектов
}
