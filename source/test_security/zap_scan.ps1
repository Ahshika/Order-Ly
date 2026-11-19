# فحص أمني ديناميكي بـ OWASP ZAP على سيرفر Order Ly مؤقت (فولدر مؤقت، بورت 18795، عمره ما بيلمس بيانات حقيقية).
# الاستخدام (من فولدر source):
#   powershell -ExecutionPolicy Bypass -File test_security\zap_scan.ps1 -Zap D:\Programs\Testing-Tools\bin\zap.cmd [-Out <folder>]
param(
  [Parameter(Mandatory)] [string]$Zap,
  [string]$Out = '',
  [int]$Port = 18795,
  [int]$ActiveMinutes = 12
)
$ErrorActionPreference = 'Continue'
# في PowerShell 5.1 الـ $PSScriptRoot بيبقى فاضي جوه param لما فيه Mandatory
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Out) { $Out = Join-Path $here '..\..\test-results\security\zap' }
$source = Split-Path $here -Parent
New-Item -ItemType Directory -Force $Out | Out-Null
$Out = (Resolve-Path $Out).Path
Remove-Item "$Out\seed.json", "$Out\stop" -ErrorAction SilentlyContinue

# 1) نفس سيرفر اختبار الضغط (منيو + 310 ترابيزة + درج مفتوح)
$env:LOAD_OUT = $Out; $env:LOAD_PORT = "$Port"
$server = Start-Process flutter -ArgumentList 'test', 'test_load/load_server_test.dart' -WorkingDirectory $source `
  -RedirectStandardOutput "$Out\server-test.log" -RedirectStandardError "$Out\server-test.err" -PassThru -NoNewWindow
while (-not (Test-Path "$Out\seed.json")) { if ($server.HasExited) { throw "server did not start" }; Start-Sleep 1 }
$seed = Get-Content "$Out\seed.json" -Raw | ConvertFrom-Json
$base = $seed.base
$h = @{ Authorization = "Bearer $($seed.token)" }

# حساب فيه طلب، عشان ZAP يلاقي مسارات بـ IDs حقيقية
$check = Invoke-RestMethod "$base/api/checks" -Method Post -Headers $h -ContentType 'application/json' -Body (@{ type = 'dine_in'; tableId = $seed.tables[0] } | ConvertTo-Json)
$cid = $check.check.id
$order = Invoke-RestMethod "$base/api/checks/$cid/orders" -Method Post -Headers $h -ContentType 'application/json; charset=utf-8' `
  -Body ([Text.Encoding]::UTF8.GetBytes((@{ lines = @(@{ itemId = $seed.items[1].id; qty = 1 }) } | ConvertTo-Json -Depth 5)))
$oid = $order.orderId
$line = $order.orders[0].items[0].id
$item = $seed.items[1].id

$get = @('/api/info', '/api/auth/me', '/api/shop', '/api/menu', '/api/floor', '/api/checks', "/api/checks/$cid", "/api/checks?status=all&q=1",
  '/api/orders', '/api/orders?status=active', '/api/kds', '/api/live', '/api/calls', '/api/register', '/api/register/history',
  '/api/pay-methods', '/api/customers?q=010', '/api/users', '/api/audit?limit=5', '/api/ingredients', '/api/suppliers', '/api/purchases',
  '/api/reports/summary', '/api/reports/today', '/api/promotions', '/api/feedback', '/api/backups', '/api/license', '/api/files/x',
  '/api/print/claim?stations=receipt')
$post = @(
  @('/api/auth/login', '{"username":"owner","password":"wrong-pass"}'),
  @('/api/checks', "{`"type`":`"takeaway`",`"customerName`":`"zap`",`"note`":`"n`"}"),
  @("/api/checks/$cid/orders", "{`"lines`":[{`"itemId`":`"$item`",`"qty`":1,`"note`":`"x`"}]}"),
  @("/api/checks/$cid/customer", '{"phone":"01012345678","name":"zap"}'),
  @("/api/checks/$cid/print", '{"kind":"bill"}'),
  @("/api/order-items/$line/status", '{"status":"ready"}'),
  @("/api/orders/$oid/ready", '{}'),
  @('/api/register/moves', '{"type":"expense","amountCents":100,"note":"zap"}'),
  @('/api/suppliers', '{"name":"zap","phone":"0100","notes":"n"}'),
  @('/api/ingredients', '{"name":"zap","unit":"g","qty":5}')
)
$reqs = @($get | ForEach-Object { "    - url: `"$base$_`"`n      method: GET" }) + @($post | ForEach-Object { "    - url: `"$base$($_[0])`"`n      method: POST`n      headers: [`"Content-Type: application/json`"]`n      data: '$($_[1])'" })
$plan = @"
env:
  contexts:
    - name: orderly
      urls: ["$base"]
      includePaths: ['$([regex]::Escape($base)).*']
  parameters:
    failOnError: false
    progressToStdout: true
jobs:
  - type: replacer
    parameters: { deleteAllRules: true }
    rules:
      - description: auth
        matchType: req_header
        matchString: Authorization
        replacementString: "Bearer $($seed.token)"
  - type: requestor
    requests:
$($reqs -join "`n")
  - type: passiveScan-wait
    parameters: { maxDuration: 2 }
  - type: activeScan
    parameters: { context: orderly, maxScanDurationInMins: $ActiveMinutes, maxRuleDurationInMins: 2, threadPerHost: 4 }
  - type: passiveScan-wait
    parameters: { maxDuration: 2 }
  - type: report
    parameters: { template: traditional-html, reportDir: "$($Out -replace '\\','/')", reportFile: zap-report }
  - type: report
    parameters: { template: traditional-json, reportDir: "$($Out -replace '\\','/')", reportFile: zap-report }
"@
[IO.File]::WriteAllText("$Out\plan.yaml", $plan, (New-Object Text.UTF8Encoding $false))

# 2) ZAP من غير واجهة (فولدر بيانات مؤقت عشان مايلمسش إعدادات ZAP بتاعتك)
$zapHome = Join-Path $env:TEMP ("zap-orderly-" + [guid]::NewGuid())
& $Zap -cmd -dir $zapHome -autorun "$Out\plan.yaml" 2>&1 | Tee-Object "$Out\zap.log" | Select-String 'Job |ERROR|Alert|completed' | Select-Object -Last 30

New-Item "$Out\stop" -ItemType File -Force | Out-Null
$server.WaitForExit()
Remove-Item $zapHome -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item "$Out\server.log" "$Out\server-during-zap.log" -ErrorAction SilentlyContinue
"ZAP done: $Out\zap-report.html"
