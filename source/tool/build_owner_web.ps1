# Builds the owner app (Flutter web, owner mode) into firebase/public/owner, ready for Firebase Hosting.
# CanvasKit comes from Google's CDN here (the owner always has internet), so Hosting only serves the app itself.
# Usage (from the source folder):  powershell -ExecutionPolicy Bypass -File tool\build_owner_web.ps1 [-Deploy]
param([switch]$Deploy)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
$out = Join-Path $root 'build\web_owner'
flutter build web --release --dart-define=ORDERLY_OWNER=true --base-href /owner/ -o $out
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
