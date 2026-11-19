# اختبار الضغط مع مراقبة لايف: Prometheus + Grafana مؤقتين (فولدر مؤقت وبورتات تانية، مابيلمسوش أي Grafana متسطب عندك).
# - k6 بيبعت أرقامه لـ Prometheus (remote write)، والسيرفر بيعرض أرقامه على LOAD_METRICS_PORT وPrometheus بيقراها كل ثانية.
# - Grafana فيه داشبورد جاهزة، وفي الآخر بنحفظ صورة منها ونسخة من الأرقام.
# الاستخدام (من فولدر source):
#   powershell -ExecutionPolicy Bypass -File test_load\run_monitored.ps1 -K6 <k6.exe> -Prometheus <prometheus.exe> -Grafana <grafana.exe> [-Script orders.js] [-Out <folder>]
param(
  [string]$K6 = 'k6',
  [string]$Prometheus = 'prometheus',
  [string]$Grafana = 'grafana',
  [string]$Script = 'orders.js',
  [string]$Out = ''
)
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Out) { $Out = Join-Path $here ("results-monitored-" + (Get-Date -Format 'yyyy-MM-dd-HHmm')) }
New-Item -ItemType Directory -Force $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$tmp = Join-Path $env:TEMP ("orderly-monitor-" + [guid]::NewGuid())
New-Item -ItemType Directory -Force "$tmp\prom", "$tmp\graf\provisioning\datasources", "$tmp\graf\provisioning\dashboards", "$tmp\graf\dashboards", `
  "$tmp\graf\data", "$tmp\graf\logs", "$tmp\graf\plugins" | Out-Null # Grafana مابيعملش فولدر البيانات لوحده
$utf8 = New-Object Text.UTF8Encoding $false
$promPort = 19090; $grafPort = 13000; $metricsPort = 18791

# ---- Prometheus
[IO.File]::WriteAllText("$tmp\prom\prometheus.yml", @"
global: { scrape_interval: 1s, evaluation_interval: 5s }
scrape_configs:
  - job_name: orderly-server
    static_configs: [ { targets: ['127.0.0.1:$metricsPort'] } ]
"@, $utf8)
$prom = Start-Process $Prometheus -ArgumentList "--config.file=`"$tmp\prom\prometheus.yml`"", "--storage.tsdb.path=`"$tmp\prom\data`"", "--web.listen-address=127.0.0.1:$promPort", '--web.enable-remote-write-receiver' `
  -RedirectStandardOutput "$tmp\prom.out" -RedirectStandardError "$Out\prometheus.log" -PassThru -WindowStyle Hidden

# ---- Grafana (نسخة مستقلة: فولدر بيانات مؤقت، دخول anonymous على localhost بس)
$graf = $Grafana; $home_ = Split-Path (Split-Path $graf -Parent) -Parent
[IO.File]::WriteAllText("$tmp\graf\custom.ini", @"
[paths]
data = $tmp\graf\data
logs = $tmp\graf\logs
plugins = $tmp\graf\plugins
provisioning = $tmp\graf\provisioning
[server]
http_addr = 127.0.0.1
http_port = $grafPort
[auth.anonymous]
enabled = true
org_role = Admin
[auth]
disable_login_form = true
[analytics]
reporting_enabled = false
check_for_updates = false
check_for_plugin_updates = false
[news]
news_feed_enabled = false
"@, $utf8)
[IO.File]::WriteAllText("$tmp\graf\provisioning\datasources\prom.yaml", @"
apiVersion: 1
datasources:
  - { name: Prometheus, uid: prom, type: prometheus, access: proxy, url: 'http://127.0.0.1:$promPort', isDefault: true, jsonData: { timeInterval: 1s } }
"@, $utf8)
[IO.File]::WriteAllText("$tmp\graf\provisioning\dashboards\files.yaml", @"
apiVersion: 1
providers:
  - { name: orderly, type: file, options: { path: '$($tmp -replace '\\','/')/graf/dashboards' } }
"@, $utf8)
Copy-Item "$here\grafana_live_dashboard.json" "$tmp\graf\dashboards\orderly.json"
Copy-Item "$here\grafana_live_dashboard.json" "$Out\grafana-live-dashboard.json"
# Start-Process مابيحطش علامات تنصيص، و"Program Files" فيها مسافة
$grafProc = Start-Process $graf -ArgumentList 'server', "--homepath=`"$home_`"", "--config=`"$tmp\graf\custom.ini`"" `
  -RedirectStandardOutput "$tmp\graf.out" -RedirectStandardError "$Out\grafana.log" -PassThru -WindowStyle Hidden

foreach ($u in "http://127.0.0.1:$promPort/-/ready", "http://127.0.0.1:$grafPort/api/health") {
  for ($i = 0; $i -lt 60; $i++) { try { Invoke-WebRequest $u -UseBasicParsing -TimeoutSec 2 | Out-Null; break } catch { Start-Sleep 1 } }
}

# ---- الاختبار نفسه
$env:LOAD_METRICS_PORT = "$metricsPort"
$env:K6_PROMETHEUS_RW_SERVER_URL = "http://127.0.0.1:$promPort/api/v1/write"
$env:K6_PROMETHEUS_RW_TREND_STATS = 'p(50),p(95),p(99),max'
$env:K6_PROMETHEUS_RW_PUSH_INTERVAL = '2s'
$start = [DateTimeOffset]::UtcNow
& powershell -ExecutionPolicy Bypass -File "$here\run.ps1" -K6 $K6 -Script $Script -Out $Out -ExtraOut 'experimental-prometheus-rw'
$end = [DateTimeOffset]::UtcNow
Start-Sleep 5

# ---- نحفظ الأرقام من Prometheus، وصورة من Grafana
$queries = [ordered]@{
  orders_per_sec = 'sum(rate(k6_orders_ok_total[15s]))'
  order_time_p95_ms = 'max(k6_order_time_p95) * 1000'
  screen_time_p95_ms = 'max(k6_screen_time_p95) * 1000'
  http_failed_rate = 'max(k6_http_req_failed_rate)'
  vus = 'max(k6_vus)'
  server_loop_lag_ms = 'max(orderly_event_loop_lag_ms)'
  server_rss_mb = 'max(orderly_rss_bytes) / 1048576'
  db_mb = 'max(orderly_db_bytes) / 1048576'
  open_checks = 'max(orderly_open_checks)'
  kds_orders = 'max(orderly_kds_orders)'
}
$export = [ordered]@{}
foreach ($q in $queries.GetEnumerator()) {
  try {
    $r = Invoke-RestMethod "http://127.0.0.1:$promPort/api/v1/query_range" -Body @{ query = $q.Value; start = $start.ToUnixTimeSeconds(); end = $end.ToUnixTimeSeconds(); step = '5' } -TimeoutSec 20
    $vals = @($r.data.result | ForEach-Object { $_.values } | ForEach-Object { [double]$_[1] } | Where-Object { -not [double]::IsNaN($_) })
    $export[$q.Key] = [ordered]@{ query = $q.Value; points = $vals.Count; max = ($vals | Measure-Object -Maximum).Maximum; avg = ($vals | Measure-Object -Average).Average; series = $r.data.result }
  } catch { $export[$q.Key] = @{ query = $q.Value; error = "$_" } }
}
[IO.File]::WriteAllText("$Out\prometheus-export.json", ($export | ConvertTo-Json -Depth 8), $utf8)
$from = $start.ToUnixTimeMilliseconds() - 10000; $to = $end.ToUnixTimeMilliseconds() + 10000
$env:SHOT_URL = "http://127.0.0.1:$grafPort/d/orderly-live/order-ly-live-load?orgId=1&from=$from&to=$to&kiosk"
$env:SHOT_OUT = "$Out\grafana-dashboard.png"
Push-Location (Join-Path (Split-Path $here -Parent) 'test_web')
node -e "const {chromium}=require('@playwright/test');(async()=>{const b=await chromium.launch();const p=await b.newPage({viewport:{width:1600,height:1300}});await p.goto(process.env.SHOT_URL);await p.waitForTimeout(9000);await p.screenshot({path:process.env.SHOT_OUT,fullPage:true});await b.close();})().catch(e=>{console.error(e);process.exit(1)})"
Pop-Location

# ---- نقفل اللي إحنا فتحناه بس
foreach ($p in $prom, $grafProc) { if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force } }
Start-Sleep 2
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
"monitored run done: $Out"
