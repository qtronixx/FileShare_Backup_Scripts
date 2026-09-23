param(
    [string]$CommonPath  = 'C:\Scripts\common.psd1',
    [string]$SourceMesId = ''
)
# ...
if (-not $SourceMesId) { $SourceMesId = "debug_$(Get-Date -Format yyyyMMddHHmmss)" }

# ASCII-only debug script. No Cyrillic on purpose - encoding-proof.

if (-not (Test-Path -LiteralPath $CommonPath)) {
    throw "Config not found: $CommonPath. Usage: .\sd_debug.ps1 -CommonPath <path>"
}
 $cfg = Import-PowerShellDataFile -LiteralPath $CommonPath

if (-not $cfg.SdBaseUrl -or -not $cfg.SdAccessKey) {
    throw "Config loaded, but SdBaseUrl/SdAccessKey are empty - check $CommonPath"
}

 $payload = @{
    metaClass       = 'serviceCall$serviceCall'
    shortDescr      = '[DEBUG] test incident creation'
    agreement       = $cfg.SdAgreement
    descriptionRTF  = 'debug'
    clientName      = $cfg.SdClientName
    sourceMesId     = "debug_$(Get-Date -Format yyyyMMddHHmmss)"
    service         = $cfg.SdService
    responsibleTeam = $cfg.SdTeam
    baseCategory    = $cfg.SdCategory    # BISECTION: comment out this line for run #2
}

# String concatenation, not interpolation - immune to both encoding and $var? pitfalls
 $uri  = $cfg.SdBaseUrl + '/sd/services/rest/create-m2m/serviceCall?accessKey=' + $cfg.SdAccessKey + '&attrs=UUID'
 $json = $payload | ConvertTo-Json
s
try {
    $r = Invoke-RestMethod -Uri $uri -Method Post -Body $json `
         -ContentType 'application/json; charset=utf-8' -TimeoutSec 20
    "OK: $($r.UUID)"
} catch {
    "Error: $($_.Exception.Message)"
    $resp = $_.Exception.Response
    if ($resp) {
        $sr = New-Object IO.StreamReader($resp.GetResponseStream())
        "Server response body: " + $sr.ReadToEnd()
    }
}