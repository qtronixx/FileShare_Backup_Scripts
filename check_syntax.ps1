Set-Location -LiteralPath 'C:\Git\FileShare_Backup_Scripts'
try {
    $sbText = Get-Content -Raw -LiteralPath 'sync_share.ps1'
    # Попытка создать ScriptBlock — ловит синтаксические ошибки
    $null = [scriptblock]::Create($sbText)
    Write-Host 'SYNTAX_OK'
    exit 0
}
catch {
    Write-Host 'SYNTAX_ERROR'
    Write-Host $_.Exception.Message
    exit 2
}