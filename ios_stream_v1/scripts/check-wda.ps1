param(
  [string]$WdaUrl = 'http://127.0.0.1:8000/status',
  [string]$MjpegUrl = 'http://127.0.0.1:8001/'
)

$ErrorActionPreference = 'Continue'

Write-Host '== WDA status =='
try {
  Invoke-WebRequest -Uri $WdaUrl -UseBasicParsing | Select-Object -ExpandProperty Content
} catch {
  Write-Warning $_.Exception.Message
}
Write-Host "`n"

Write-Host '== MJPEG headers =='
try {
  Invoke-WebRequest -Uri $MjpegUrl -Method Head -UseBasicParsing | Format-List *
} catch {
  Write-Warning $_.Exception.Message
}
