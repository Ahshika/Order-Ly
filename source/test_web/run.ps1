# اختبار منيو العميل: سيرفر حقيقي مؤقت (fixture) + Playwright على 3 متصفحات + السيرفر بياخد الطلبات اللي اتبعتت.
# الاستخدام (من فولدر source):  powershell -ExecutionPolicy Bypass -File test_web\run.ps1 [-Out <folder>]
param([string]$Out = (Join-Path $PSScriptRoot '..\..\test-results\web'), [string]$FirefoxPath = '')
# على ويندوز Insider (26300) Firefox بتاع Playwright مابيفتحش من AppData\Local (SideBySide: mozglue)، وبيفتح عادي من Temp.
# لو مااتبعتش مسار: بنجرّبه من مكانه، ولو فشل بننسخه لـ Temp ونستخدمه من هناك.
if (-not $FirefoxPath) {
  $orig = Get-ChildItem "$env:LOCALAPPDATA\ms-playwright" -Directory -Filter 'firefox-*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
  if ($orig) {
    $exe = Join-Path $orig.FullName 'firefox\firefox.exe'
    $ok = try { Start-Process $exe -ArgumentList '--version' -Wait -NoNewWindow -RedirectStandardOutput "$env:TEMP\ff-check.txt" -ErrorAction Stop; $true } catch { $false }
    if (-not $ok) {
      $copy = Join-Path $env:TEMP "pw-$($orig.Name)"
      if (-not (Test-Path "$copy\firefox.exe")) { Copy-Item (Join-Path $orig.FullName 'firefox') $copy -Recurse }
      $FirefoxPath = "$copy\firefox.exe"
    }
  }
}
if ($FirefoxPath) { $env:FIREFOX_PATH = $FirefoxPath }
$ErrorActionPreference = 'Continue'
$source = Split-Path $PSScriptRoot -Parent
New-Item -ItemType Directory -Force $Out | Out-Null
$Out = (Resolve-Path $Out).Path
Remove-Item "$Out\fixture.json", "$Out\done", "$Out\captured" -Recurse -Force -ErrorAction SilentlyContinue
$env:WEB_OUT = $Out

$server = Start-Process flutter -ArgumentList 'test', 'test_web/menu_contract_test.dart' -WorkingDirectory $source `
  -RedirectStandardOutput "$Out\contract.log" -RedirectStandardError "$Out\contract.err" -PassThru -NoNewWindow
$null = $server.Handle # عشان ExitCode يتقري بعد ما يخلص
while (-not (Test-Path "$Out\fixture.json")) {
  if ($server.HasExited) { throw "contract server did not start, see $Out\contract.log" }
  Start-Sleep 1
}
Push-Location $PSScriptRoot
try {
  & npx playwright test 2>&1 | Tee-Object "$Out\playwright.log"
  $pw = $LASTEXITCODE
} finally {
  Pop-Location
  New-Item "$Out\done" -ItemType File -Force | Out-Null
  $server.WaitForExit()
}
"playwright exit=$pw  contract exit=$($server.ExitCode)"
