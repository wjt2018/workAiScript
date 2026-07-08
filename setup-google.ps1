<#
  setup-google.ps1
  One-time Google Calendar authorization. Runs a local loopback OAuth flow,
  opens your browser to consent, and stores a refresh token in secrets.json.
  Run this yourself in a normal PowerShell window (a browser will open).

  Before running, create an OAuth client (once):
    1. https://console.cloud.google.com/  -> create/select a project
    2. "APIs & Services" -> "Library" -> enable "Google Calendar API"
    3. "APIs & Services" -> "OAuth consent screen":
         User Type = External; fill app name + your email; Save.
         Under "Test users" add your own Google account email.
    4. "APIs & Services" -> "Credentials" -> Create Credentials
         -> OAuth client ID -> Application type = "Desktop app" -> Create
    5. Copy the Client ID and Client Secret shown.
#>
$ErrorActionPreference = "Stop"
$OutputEncoding = New-Object System.Text.UTF8Encoding $false
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch {}

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Root "lib-secrets.ps1")

Write-Host ""
$clientId = (Read-Host "Paste your Google OAuth Client ID").Trim()
$clientSecret = (Read-Host "Paste your Google OAuth Client Secret").Trim()
if (-not $clientId -or -not $clientSecret) { Write-Host "Client ID/Secret required." -ForegroundColor Red; return }

$port = 47990
$redirect = "http://127.0.0.1:$port"
$scope = "https://www.googleapis.com/auth/calendar.readonly"
$authUrl = "https://accounts.google.com/o/oauth2/v2/auth" +
  "?client_id=" + [uri]::EscapeDataString($clientId) +
  "&redirect_uri=" + [uri]::EscapeDataString($redirect) +
  "&response_type=code" +
  "&scope=" + [uri]::EscapeDataString($scope) +
  "&access_type=offline&prompt=consent"

# start loopback listener (TcpListener: no admin needed for 127.0.0.1)
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
try { $listener.Start() } catch {
  Write-Host ("Could not open port {0}: {1}" -f $port, $_.Exception.Message) -ForegroundColor Red
  return
}

Write-Host ""
Write-Host "Opening your browser to authorize Google Calendar (read-only)..." -ForegroundColor Cyan
Write-Host "If it doesn't open, paste this URL manually:" -ForegroundColor Gray
Write-Host $authUrl
Start-Process $authUrl | Out-Null

Write-Host "Waiting for you to approve in the browser..." -ForegroundColor Gray
$client = $listener.AcceptTcpClient()
$stream = $client.GetStream()
$reader = New-Object System.IO.StreamReader($stream)
$requestLine = $reader.ReadLine()

$code = $null
$m = [regex]::Match($requestLine, "code=([^&\s]+)")
if ($m.Success) { $code = [uri]::UnescapeDataString($m.Groups[1].Value) }

$html = "<!doctype html><html><body style='font-family:sans-serif;padding:40px'><h2>Authorized.</h2><p>You can close this tab and return to PowerShell.</p></body></html>"
$bytes = [System.Text.Encoding]::UTF8.GetBytes($html)
$writer = New-Object System.IO.StreamWriter($stream)
$writer.WriteLine("HTTP/1.1 200 OK")
$writer.WriteLine("Content-Type: text/html; charset=utf-8")
$writer.WriteLine("Content-Length: " + $bytes.Length)
$writer.WriteLine("Connection: close")
$writer.WriteLine("")
$writer.Write($html)
$writer.Flush()
$client.Close()
$listener.Stop()

if (-not $code) { Write-Host "No authorization code received. Try again." -ForegroundColor Red; return }

Write-Host "Exchanging code for tokens..." -ForegroundColor Gray
$tok = Invoke-RestMethod -Uri "https://oauth2.googleapis.com/token" -Method Post -Body @{
  code          = $code
  client_id     = $clientId
  client_secret = $clientSecret
  redirect_uri  = $redirect
  grant_type    = "authorization_code"
} -TimeoutSec 20

if (-not $tok.refresh_token) {
  Write-Host "No refresh_token returned. Revoke prior access at https://myaccount.google.com/permissions and re-run." -ForegroundColor Red
  return
}

$section = [pscustomobject]@{ clientId = $clientId; clientSecret = $clientSecret; refreshToken = $tok.refresh_token }
$p = Save-SecretSection -Root $Root -Section "google" -Value $section

Write-Host ""
Write-Host "OK. Google Calendar authorized (read-only)." -ForegroundColor Green
Write-Host ("Saved to {0}" -f $p) -ForegroundColor Green
Write-Host ""
Write-Host "Test it now:" -ForegroundColor Cyan
Write-Host ('  . .\collect-calendar.ps1; Get-CalendarDigest -DateStr (Get-Date -Format yyyy-MM-dd) -Root "' + $Root + '"')
