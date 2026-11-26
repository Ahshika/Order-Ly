# Builds the owner app (Flutter web, owner mode) into firebase/public/owner, ready for Firebase Hosting.
# CanvasKit comes from Google's CDN here (the owner always has internet), so Hosting only serves the app itself.
# Usage (from the source folder):  powershell -ExecutionPolicy Bypass -File tool\build_owner_web.ps1 [-Deploy]
param([switch]$Deploy)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
# مفتاح Firebase بييجي من config/firebase.json (متجاهل في git). انسخ firebase.example.json لو مش موجود.
$fbConfig = Join-Path $root 'configirebase.json'
if (-not (Test-Path $fbConfig)) { throw 'configirebase.json مش موجود: انسخ configirebase.example.json وحط مفتاح Firebase فيه' }
$fbDefine = "--dart-define-from-file=$fbConfig"
$out = Join-Path $root 'build\web_owner'
flutter build web --release --dart-define=ORDERLY_OWNER=true --base-href /owner/ -o $out $fbDefine
if ($LASTEXITCODE -ne 0) { throw 'owner web build failed' }
$target = Join-Path $root 'firebase\public\owner'
if (Test-Path $target) { Remove-Item $target -Recurse -Force }
Copy-Item $out $target -Recurse
# Source maps and the staff-only manifest are not needed on Hosting
Get-ChildItem $target -Recurse -Include *.symbols, *.map | Remove-Item -Force
Write-Host "owner app: $target"
if ($Deploy) {
  Push-Location (Join-Path $root 'firebase')
  try { firebase deploy --only hosting } finally { Pop-Location }
}
