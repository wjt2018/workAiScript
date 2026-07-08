<#
  setup-slack-send.ps1
  One-time: store the Slack BOT token (xoxb-...) so the daily report can be
  DM'd to you by the bot. Run this yourself in a normal PowerShell window.

  Where to find the bot token:
    https://api.slack.com/apps -> your app -> OAuth & Permissions
    -> "OAuth Tokens for Your Workspace" -> "Bot User OAuth Token" (xoxb-...)
  The bot needs at least the "chat:write" scope (send messages). To be DM'd
  directly it also needs "im:write". If those are missing, add them under
  "Bot Token Scopes", reinstall the app, then run this again.
#>
$ErrorActionPreference = "Stop"
$OutputEncoding = New-Object System.Text.UTF8Encoding $false
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch {}

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Root "lib-secrets.ps1")

Write-Host ""
Write-Host "Paste your Slack Bot User OAuth Token (xoxb-...):" -ForegroundColor Cyan
$token = (Read-Host).Trim()
if ($token -notmatch "^xoxb-") {
  Write-Host "That doesn't look like a bot token (should start with xoxb-)." -ForegroundColor Red
  return
}

Write-Host "Validating with Slack (auth.test)..." -ForegroundColor Gray
$resp = Invoke-RestMethod -Uri "https://slack.com/api/auth.test" -Method Post -Headers @{ Authorization = "Bearer $token" } -TimeoutSec 20
if (-not $resp.ok) {
  Write-Host ("Slack rejected the token: {0}" -f $resp.error) -ForegroundColor Red
  return
}

# merge botToken into the existing slack section (keep userToken/userId)
$sec = Get-Secrets $Root
$slack = if ($sec.slack) { $sec.slack } else { [pscustomobject]@{} }
if ($slack.PSObject.Properties.Name -contains "botToken") { $slack.botToken = $token }
else { $slack | Add-Member -NotePropertyName botToken -NotePropertyValue $token -Force }
$p = Save-SecretSection -Root $Root -Section "slack" -Value $slack

Write-Host ""
Write-Host ("OK. Bot '{0}' saved for sending." -f $resp.user) -ForegroundColor Green
Write-Host ("Saved to {0}" -f $p) -ForegroundColor Green
Write-Host ""
Write-Host "Test sending now:" -ForegroundColor Cyan
Write-Host ('  . .\send-slack.ps1; Send-SlackReport -Text "test from daily-report" -Root "' + $Root + '" -Logger { param($m) Write-Host $m }')
