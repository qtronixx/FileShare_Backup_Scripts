@{
    TaskName      = 'Файловая шара (s-fs03)'
    Source        = '\\s-fs03\Файловое хранилище'
    Destination   = 'D:\Bckp\File_Share'
    LogDir        = 'D:\Logs\FileShare_bckp_logs'
    LogFilePrefix = 'DataShare_Sync_Log'
    CopyAcls      = $true        # /SEC — для шары права нужны

    ExcludedFiles = @('Thumbs.db', '~*.*', '~$*', '*.tmp', '.DS_Store', 'desktop.ini', '*.log', '*.crdownload')
    ExcludedDirs  = @('*\Cache', '*\Temp')
}
