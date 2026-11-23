# Deploys the Order Ly database rules to a shop's own Firebase project.
# The customer menu page stays on the main project (one page for every shop), so only the rules go here.
# Usage (from the "source" folder):
#   powershell -ExecutionPolicy Bypass -File tool\deploy_shop_firebase.ps1 -Project cafe-elnour
# Several shops at once (after a rules change):
#   powershell -ExecutionPolicy Bypass -File tool\deploy_shop_firebase.ps1 -Project cafe-elnour,cafe-elfayrouz
param([Parameter(Mandatory = $true)][string[]]$Project)
$ErrorActionPreference = 'Stop'
$firebaseDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'firebase'
Push-Location $firebaseDir
try {
  foreach ($p in $Project) {
    Write-Host "== $p : deploying database rules"
    & firebase deploy --only database --project $p --non-interactive
    if ($LASTEXITCODE -ne 0) { throw "deploy failed for $p (does your Google account have Editor access, and is Realtime Database created?)" }
    # Quick check from outside: public menu data readable, customer messages closed
    $db = (& firebase database:instances:list --project $p 2>$null | Select-String -Pattern 'https://\S+' -AllMatches).Matches | Select-Object -First 1
    if ($db) {
      $base = $db.Value.TrimEnd('/')
      $pub = try { (Invoke-WebRequest "$base/cafes/check/pub.json" -UseBasicParsing).StatusCode } catch { $_.Exception.Response.StatusCode.value__ }
      $inbox = try { (Invoke-WebRequest "$base/inbox/check.json" -UseBasicParsing).StatusCode } catch { $_.Exception.Response.StatusCode.value__ }
      Write-Host "   $base  pub=$pub (want 200)  inbox=$inbox (want 401)"
    }
  }
} finally {
  Pop-Location
}
Write-Host 'Done. Remember: Authentication > Sign-in method > Email/Password must be enabled on each project.'
