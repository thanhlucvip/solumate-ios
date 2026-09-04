param(
  [int]$HostWdaPort = 8000,
  [int]$HostMjpegPort = 8001,
  [int]$HostRealtimeControlPort = 8003,
  [int]$DeviceWdaPort = 8000,
  [int]$DeviceMjpegPort = 8001,
  [int]$DeviceRealtimeControlPort = 8003
)

$ErrorActionPreference = 'Stop'

Write-Host "Forwarding WDA:   localhost:$HostWdaPort -> device:$DeviceWdaPort"
$p1 = Start-Process -FilePath "ios" -ArgumentList @("forward", "$HostWdaPort", "$DeviceWdaPort") -PassThru -NoNewWindow

Write-Host "Forwarding MJPEG: localhost:$HostMjpegPort -> device:$DeviceMjpegPort"
$p2 = Start-Process -FilePath "ios" -ArgumentList @("forward", "$HostMjpegPort", "$DeviceMjpegPort") -PassThru -NoNewWindow

$stdout = "Forwarding CTRL:  localhost:$HostRealtimeControlPort -> device:$DeviceRealtimeControlPort"
Write-Host $stdout
$p3 = Start-Process -FilePath "ios" -ArgumentList @("forward", "$HostRealtimeControlPort", "$DeviceRealtimeControlPort") -PassThru -NoNewWindow

try {
  Wait-Process -Id $p1.Id, $p2.Id, $p3.Id
} finally {
  foreach ($p in @($p1, $p2, $p3)) {
    if ($null -ne $p -and -not $p.HasExited) {
      Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    }
  }
}
