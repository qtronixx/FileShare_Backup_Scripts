# tasks\_sdtest.psd1
@{
    TaskName      = '[SD-ТЕСТ] шара'
    Source        = '\\nonexistent-host\share'
    Destination   = 'D:\Bckp\_sdtest'
    LogDir        = 'D:\Logs\_sdtest'
    LogFilePrefix = 'SD_Test_Log'
	SendToServiceDesk = $true    # SD включён только для тестовой задачи
}