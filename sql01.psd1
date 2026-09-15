@{
    TaskName      = 'Базы данных SQL (s-prn01)'
    Source        = '\\s-prn01\backup_sql'
    Destination   = 'D:\Bckp\Databases'
    LogDir        = 'D:\Logs\SQL_bckp_logs'
    LogFilePrefix = 'SQL_Backup_Log'
    CopyAcls      = $false       # /SEC не нужен — права SQL-шары в бэкапе не нужны

    ExcludedFiles = @('~*.*', '~$*', '*.tmp', '*.crdownload', '*.log')  # уберите '*.log', если нужны sqlagent-логи
    ExcludedDirs  = @()

    # MessageThreadId = '20'     # опционально: отдельный топик для SQL-задачи
}
