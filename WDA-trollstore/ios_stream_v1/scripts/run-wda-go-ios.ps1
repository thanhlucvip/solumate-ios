param(
  [string]$IpaPath,
  [string]$BundleId = 'com.idbbagent.troll',
  [string]$XCTestConfig = 'WebDriverAgentRunner.xctest',
  [int]$WdaPort = 8000,
  [int]$MjpegPort = 8001,
  [int]$H264Port = -1,
  [int]$RealtimeControlPort = 8003,
  [int]$MjpegScale = 45,
  [int]$MjpegQuality = 20,
  [string]$StartupPassword = $env:WDA_STARTUP_PASSWORD,
  [string]$WdaAuthToken = $env:WDA_AUTH_TOKEN,
  [string]$PointArrayEnabled = $env:SOLUMATE_WDA_ENABLE_POINT_ARRAY,
  [string]$PointArraySecret = $env:SOLUMATE_WDA_SWIPE_SECRET,
  [string]$AllowUnsignedPointArray = $env:SOLUMATE_WDA_ALLOW_UNSIGNED_POINT_ARRAY,
  [string]$Udid = $env:GO_IOS_UDID,
  [switch]$SkipInstall
)

$ErrorActionPreference = 'Stop'

function Write-CommandOutput {
  param(
    [Parameter(ValueFromPipeline = $true)]
    [object]$InputObject
  )

  process {
    if ($null -ne $InputObject) {
      Write-Host $InputObject.ToString()
    }
  }
}

function Add-PrefixedEnvArgs {
  param(
    [string[]]$Arguments,
    [string]$Prefix
  )

  $prefixed = Get-ChildItem Env: | Where-Object { $_.Name.StartsWith($Prefix, [System.StringComparison]::Ordinal) } | Sort-Object Name
  foreach ($entry in $prefixed) {
    $Arguments += "--env=$($entry.Name)=$($entry.Value)"
  }

  return $Arguments
}

function Invoke-IosCapture {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments
  )

  $stdoutPath = [System.IO.Path]::GetTempFileName()
  $stderrPath = [System.IO.Path]::GetTempFileName()

  try {
    $process = Start-Process `
      -FilePath 'ios' `
      -ArgumentList $Arguments `
      -Wait `
      -NoNewWindow `
      -PassThru `
      -RedirectStandardOutput $stdoutPath `
      -RedirectStandardError $stderrPath

    $stdout = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -LiteralPath $stdoutPath } else { @() }
    $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath } else { @() }
    $output = @($stdout + $stderr)
    $output | Write-CommandOutput

    return [pscustomobject]@{
      ExitCode = $process.ExitCode
      Output = $output
    }
  }
  finally {
    Remove-Item -LiteralPath $stdoutPath, $stderrPath -ErrorAction SilentlyContinue
  }
}

function Ensure-DeveloperImageMounted {
  Write-Host 'Checking Developer Image mount state...'

  $imageListArgs = @()
  if (-not [string]::IsNullOrWhiteSpace($Udid)) {
    $imageListArgs += "--udid=$Udid"
  }
  $imageListArgs += @('image', 'list')
  $imageList = Invoke-IosCapture -Arguments $imageListArgs
  if ($imageList.ExitCode -ne 0) {
    throw "ios image list failed with exit code $($imageList.ExitCode)"
  }

  $imageListText = ($imageList.Output | Out-String)
  if ($imageListText -match '"msg":"none"' -or $imageListText -match '\bnone\b') {
    Write-Host 'Developer Image is not mounted. Running ios image auto...'

    $imageAutoArgs = @()
    if (-not [string]::IsNullOrWhiteSpace($Udid)) {
      $imageAutoArgs += "--udid=$Udid"
    }
    $imageAutoArgs += @('image', 'auto')
    $imageAuto = Invoke-IosCapture -Arguments $imageAutoArgs
    if ($imageAuto.ExitCode -ne 0) {
      throw "ios image auto failed with exit code $($imageAuto.ExitCode)"
    }
  }
}

if (-not $SkipInstall) {
  if ([string]::IsNullOrWhiteSpace($IpaPath)) {
    throw 'IpaPath is required unless -SkipInstall is used.'
  }
  if (-not (Test-Path -LiteralPath $IpaPath -PathType Leaf)) {
    throw "IPA file not found: $IpaPath"
  }

  Write-Host "Installing IPA: $IpaPath"
  if ([string]::IsNullOrWhiteSpace($Udid)) {
    ios install --path="$IpaPath"
  } else {
    ios --udid="$Udid" install --path="$IpaPath"
  }
  if ($LASTEXITCODE -ne 0) {
    throw "ios install failed with exit code $LASTEXITCODE"
  }
}

Ensure-DeveloperImageMounted

if ([string]::IsNullOrWhiteSpace($StartupPassword)) {
  Write-Warning 'WDA_STARTUP_PASSWORD is empty. If your WDA build enforces startup password, runwda can abort.'
}
if (
  -not [string]::IsNullOrWhiteSpace($PointArrayEnabled) -and
  [string]::IsNullOrWhiteSpace($PointArraySecret) -and
  [string]::IsNullOrWhiteSpace($AllowUnsignedPointArray)
) {
  Write-Warning 'SOLUMATE_WDA_ENABLE_POINT_ARRAY is set but SOLUMATE_WDA_SWIPE_SECRET is empty. Secure builds reject unsigned pointArray requests.'
}

Write-Host "Starting WDA with bundle id: $BundleId (WDA:$WdaPort, MJPEG:$MjpegPort, H264:$H264Port, CTRL:$RealtimeControlPort, scale:$MjpegScale, quality:$MjpegQuality)"

$runWdaArgs = @()
if (-not [string]::IsNullOrWhiteSpace($Udid)) {
  $runWdaArgs += "--udid=$Udid"
}
$runWdaArgs += @(
  'runwda',
  "--bundleid=$BundleId",
  "--testrunnerbundleid=$BundleId",
  "--env=WDA_PRODUCT_BUNDLE_IDENTIFIER=$BundleId",
  "--xctestconfig=$XCTestConfig",
  "--env=USE_PORT=$WdaPort",
  "--env=MJPEG_SERVER_PORT=$MjpegPort",
  "--env=H264_SERVER_PORT=$H264Port",
  "--env=WDA_REALTIME_CONTROL_ENABLED=1",
  "--env=WDA_REALTIME_CONTROL_PORT=$RealtimeControlPort",
  "--env=MJPEG_SCALING_FACTOR=$MjpegScale",
  "--env=MJPEG_SERVER_SCREENSHOT_QUALITY=$MjpegQuality",
  '--log-output=-'
)
if (-not [string]::IsNullOrWhiteSpace($StartupPassword)) {
  $runWdaArgs += "--env=WDA_STARTUP_PASSWORD=$StartupPassword"
}
if (-not [string]::IsNullOrWhiteSpace($WdaAuthToken)) {
  $runWdaArgs += "--env=WDA_AUTH_TOKEN=$WdaAuthToken"
}
if (-not [string]::IsNullOrWhiteSpace($PointArrayEnabled)) {
  $runWdaArgs += "--env=SOLUMATE_WDA_ENABLE_POINT_ARRAY=$PointArrayEnabled"
}
if (-not [string]::IsNullOrWhiteSpace($PointArraySecret)) {
  $runWdaArgs += "--env=SOLUMATE_WDA_SWIPE_SECRET=$PointArraySecret"
}
if (-not [string]::IsNullOrWhiteSpace($AllowUnsignedPointArray)) {
  $runWdaArgs += "--env=SOLUMATE_WDA_ALLOW_UNSIGNED_POINT_ARRAY=$AllowUnsignedPointArray"
}
$runWdaArgs = Add-PrefixedEnvArgs -Arguments $runWdaArgs -Prefix 'WDA_IOHID_'
$runWdaArgs = Add-PrefixedEnvArgs -Arguments $runWdaArgs -Prefix 'WDA_REALTIME_TOUCH_'

$runWda = Invoke-IosCapture -Arguments $runWdaArgs

if ($runWda.ExitCode -ne 0) {
  $runWdaText = ($runWda.Output | Out-String)

  if ($runWdaText -match 'Have you mounted the Developer Image\?') {
    throw "ios runwda failed with exit code $($runWda.ExitCode). Developer Image is still missing or mount did not stick. Try reconnecting the device, unlock it, trust this computer again, then rerun the script."
  }

  if ($runWdaText -match 'panic: runtime error: invalid memory address or nil pointer dereference') {
    throw "ios runwda crashed inside go-ios with exit code $($runWda.ExitCode). The WDA app is likely installed, but go-ios itself panicked while starting XCTest. Try unplug/replug + unlock the device, rerun the script, and if it still fails test another go-ios version or another host."
  }

  throw "ios runwda failed with exit code $($runWda.ExitCode)"
}
