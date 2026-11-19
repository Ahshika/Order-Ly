# تطبيق الأندرويد الحقيقي على محاكي، بأسوأ السيناريوهات (Appium + UiAutomator2).
# المحاكي بيشتغل read-only (أي تغيير بيتمسح لما يتقفل)، وAppium على 127.0.0.1 بس، والسيرفر مؤقت على فولدر مؤقت.
# الاستخدام (من فولدر source، بعد flutter build apk --debug --target-platform android-x64):
#   powershell -ExecutionPolicy Bypass -File test_android\run.ps1 -Avd <avd-name> [-Out <folder>]
param([string]$Avd = 'fiberlens_phone', [string]$Out = '')
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$source = Split-Path $here -Parent
if (-not $Out) { $Out = Join-Path $here '..\..\test-results\android' }
New-Item -ItemType Directory -Force "$Out\server" | Out-Null
$Out = (Resolve-Path $Out).Path
Remove-Item "$Out\server\seed.json", "$Out\server\stop" -ErrorAction SilentlyContinue
$sdk = "$env:LOCALAPPDATA\Android\Sdk"; $adb = "$sdk\platform-tools\adb.exe"

$emu = Start-Process "$sdk\emulator\emulator.exe" -ArgumentList '-avd', $Avd, '-read-only', '-no-snapshot', '-no-audio', '-no-boot-anim', '-gpu', 'swiftshader_indirect', '-no-window' `
  -RedirectStandardOutput "$Out\emulator.log" -RedirectStandardError "$Out\emulator.err" -PassThru -WindowStyle Hidden
$appium = Start-Process node -ArgumentList "`"$env:APPDATA\npm\node_modules\appium\index.js`"", '--address', '127.0.0.1', '--port', '4723', '--log', "`"$Out\appium.log`"", '--log-level', 'info' `
  -PassThru -WindowStyle Hidden -RedirectStandardError "$Out\appium.err"
$env:LOAD_OUT = "$Out\server"; $env:LOAD_PORT = '18797'
$server = Start-Process flutter -ArgumentList 'test', 'test_load/load_server_test.dart' -WorkingDirectory $source `
  -RedirectStandardOutput "$Out\server\server-test.log" -RedirectStandardError "$Out\server\server-test.err" -PassThru -NoNewWindow
try {
  & $adb wait-for-device
  $t0 = Get-Date; do { Start-Sleep 3; $b = (& $adb shell getprop sys.boot_completed 2>$null) } until ($b -match '1' -or ((Get-Date) - $t0).TotalSeconds -gt 300)
  while (-not (Test-Path "$Out\server\seed.json")) { if ($server.HasExited) { throw 'server did not start' }; Start-Sleep 1 }
  for ($i = 0; $i -lt 30; $i++) { try { Invoke-WebRequest http://127.0.0.1:4723/status -UseBasicParsing -TimeoutSec 2 | Out-Null; break } catch { Start-Sleep 1 } }
  Push-Location $source
  python -I test_android\run_flows.py $Out "$Out\server\seed.json"
  Pop-Location
} finally {
  New-Item "$Out\server\stop" -ItemType File -Force | Out-Null
  & $adb emu kill 2>$null | Out-Null
  Start-Sleep 5
  foreach ($p in $appium, $emu) { if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } }
  $server.WaitForExit(60000) | Out-Null
}
