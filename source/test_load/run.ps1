# اختبار الضغط كامل: سيرفر مؤقت + k6 (5 دقايق) + تحليل + داشبورد جرافانا.
# الاستخدام (من فولدر source):  powershell -ExecutionPolicy Bypass -File test_load\run.ps1 -K6 C:\path\to\k6.exe
param(
  [string]$K6 = 'k6',
  # orders.js = الزيادة التدريجية (5 دقايق)، spike.js = زحمة مفاجئة + طلبات بايظة (دقيقتين)
  [string]$Script = 'orders.js',
  # مخرج إضافي لـ k6، مثلاً experimental-prometheus-rw (بيستخدمه run_monitored.ps1)
  [string]$ExtraOut = '',
  [string]$Out = (Join-Path $PSScriptRoot ("results-" + (Get-Date -Format 'yyyy-MM-dd-HHmm')))
)
$ErrorActionPreference = 'Stop'
$source = Split-Path $PSScriptRoot -Parent
New-Item -ItemType Directory -Force $Out | Out-Null
# مسار كامل: k6 بيشتغل من فولدر test_load، فالمسار النسبي كان بيبوظ
$Out = (Resolve-Path $Out).Path
$env:LOAD_OUT = $Out

# 1) السيرفر المؤقت (نفس كود البرنامج، فولدر مؤقت، بورت 18790)
$server = Start-Process flutter -ArgumentList 'test', 'test_load/load_server_test.dart' -WorkingDirectory $source `
  -RedirectStandardOutput "$Out\server-test.log" -RedirectStandardError "$Out\server-test.err" -PassThru -NoNewWindow
while (-not (Test-Path "$Out\seed.json")) {
  if ($server.HasExited) { throw "السيرفر ماشتغلش، شوف $Out\server-test.log" }
  Start-Sleep 2
}

# 2) k6
$env:SEED = "$Out\seed.json"
$env:K6_WEB_DASHBOARD = 'true'
$env:K6_WEB_DASHBOARD_OPEN = 'false'
$env:K6_WEB_DASHBOARD_EXPORT = "$Out\k6-report.html"
Push-Location $PSScriptRoot
# في PowerShell 5.1 أي سطر تحذير من k6 على stderr بيتحول لخطأ قاتل مع Stop وبيوقف k6 في النص
$ErrorActionPreference = 'Continue'
try {
  $outs = @('--out', "csv=$Out\k6.csv"); if ($ExtraOut) { $outs += @('--out', $ExtraOut) }
  & $K6 run @outs "--summary-export=$Out\summary.json" $Script 2>&1 | Tee-Object "$Out\k6.log" | Select-String 'THRESHOLDS|✓|✗|order_time|screen_time|orders_|server_errors'
} finally {
  Pop-Location
  New-Item "$Out\stop" -ItemType File -Force | Out-Null
  $server.WaitForExit()
}

# 3) التحليل + الداشبورد
python "$PSScriptRoot\analyze.py" $Out
python "$PSScriptRoot\grafana_dashboard.py" $Out
Remove-Item "$Out\k6.csv", "$Out\seed.json", "$Out\stop" -ErrorAction SilentlyContinue
Write-Host "النتايج في $Out (k6-report.html و grafana-dashboard.json)"
