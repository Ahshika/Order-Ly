# Staff web app test. build/web must exist first:  flutter build web --release --no-web-resources-cdn
# A temporary real server serves it; Playwright opens it as iPhone (WebKit) and Android (Chromium) with no internet.
# Usage (from the source folder):  powershell -ExecutionPolicy Bypass -File test_web\staff\run.ps1
param([string]$Out = (Join-Path $PSScriptRoot '..\..\..\test-results\staff-web'))
$ErrorActionPreference = 'Continue'
$source = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
New-Item -ItemType Directory -Force $Out | Out-Null
$Out = (Resolve-Path $Out).Path
Remove-Item "$Out\staff-fixture.json", "$Out\staff-done", "$Out\staff-sessions.json" -Force -ErrorAction SilentlyContinue
$env:WEB_OUT = $Out
$server = Start-Process flutter -ArgumentList 'test', 'test_web/staff/staff_server_test.dart' -WorkingDirectory $source `
  -RedirectStandardOutput "$Out\server.log" -RedirectStandardError "$Out\server.err" -PassThru -NoNewWindow
$null = $server.Handle
while (-not (Test-Path "$Out\staff-fixture.json")) {
  if ($server.HasExited) { throw "server did not start, see $Out\server.log" }
  Start-Sleep 1
}
Push-Location (Split-Path $PSScriptRoot -Parent)
try {
  & npx playwright test --config staff/playwright.config.js 2>&1 | Tee-Object "$Out\playwright.log"
  $pw = $LASTEXITCODE
} finally {
  Pop-Location
  New-Item "$Out\staff-done" -ItemType File -Force | Out-Null
  $server.WaitForExit()
}
"playwright exit=$pw  server exit=$($server.ExitCode)"
if ($pw -ne 0 -or $server.ExitCode -ne 0) { exit 1 }
