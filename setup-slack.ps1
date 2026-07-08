<#
  setup-slack.ps1
  One-time: paste your Slack User OAuth Token (xoxp-...), we validate it and
  store it in secrets.json. Run this yourself in a normal PowerShell window.

  How to get the token (once):
    1. https://api.slack.com/apps  ->  Create New App  ->  From scratch
       (name e.g. "MyDailyReport", pick your workspace)
    2. Left menu: OAuth & Permissions
    3. Scroll to "User Token Scopes" (NOT Bot Token Scopes) -> Add: search:read
    4. Top of page: "Install to Workspace" -> Allow
    5. Copy the "User OAuth Token" (starts with xoxp-)
#>
$ErrorActionPreference = "Stop"
$OutputEncoding = New-Object System.Text.UTF8Encoding $false
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch {}

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Root "lib-secrets.ps1")

Write-Host ""
Write-Host "Paste your Slack User OAuth Token (xoxp-...):" -ForegroundColor Cyan
$token = (Read-Host).Trim()
if ($token -notmatch "^xoxp-") {
  Write-Host "That doesn't look like a user token (should start with xoxp-)." -ForegroundColor Red
  Write-Host "Make sure you added the scope under 'User Token Scopes', not 'Bot Token Scopes'." -ForegroundColor Yellow
  return
}

Write-Host "Validating with Slack (auth.test)..." -ForegroundColor Gray
$resp = Invoke-RestMethod -Uri "https://slack.com/api/auth.test" -Method Post -Headers @{ Authorization = "Bearer $token" } -TimeoutSec 20
if (-not $resp.ok) {
  Write-Host ("Slack rejected the token: {0}" -f $resp.error) -ForegroundColor Red
  return
}

$section = [pscustomobject]@{ userToken = $token; userId = $resp.user_id; user = $resp.user; team = $resp.team }
$p = Save-SecretSection -Root $Root -Section "slack" -Value $section

Write-Host ""
Write-Host ("OK. Signed in as '{0}' in workspace '{1}'." -f $resp.user, $resp.team) -ForegroundColor Green
Write-Host ("Saved to {0}" -f $p) -ForegroundColor Green
Write-Host ""
Write-Host "Test it now:" -ForegroundColor Cyan
Write-Host ('  . .\collect-slack.ps1; Get-SlackDigest -DateStr (Get-Date -Format yyyy-MM-dd) -Root "' + $Root + '"')
