<#
  collect-calendar.ps1
  Return a text digest of your Google Calendar events on a given day, using a
  stored OAuth refresh token (set up once via setup-google.ps1). Read-only.

  Dot-source, then:  Get-CalendarDigest -DateStr "2026-07-06" -Root $Root -Logger $log
  Returns "" when Calendar isn't configured or there are no events.
#>

function Get-CalendarDigest {
  param(
    [Parameter(Mandatory = $true)][string]$DateStr,
    [Parameter(Mandatory = $true)][string]$Root,
    [scriptblock]$Logger = $null
  )
  function _log($m) { if ($Logger) { & $Logger $m } }

  . (Join-Path $Root "lib-secrets.ps1")
  $sec = Get-Secrets $Root
  $g = $sec.google
  if (-not $g -or [string]::IsNullOrWhiteSpace($g.refreshToken)) {
    _log "calendar: not configured (run setup-google.ps1), skipped"
    return ""
  }

  # 1) refresh -> access token
  try {
    $tok = Invoke-RestMethod -Uri "https://oauth2.googleapis.com/token" -Method Post -Body @{
      client_id     = $g.clientId
      client_secret = $g.clientSecret
      refresh_token = $g.refreshToken
      grant_type    = "refresh_token"
    } -TimeoutSec 20
  } catch {
    _log ("calendar: token refresh failed ({0}); re-run setup-google.ps1" -f $_.Exception.Message)
    return ""
  }
  $access = $tok.access_token
  if (-not $access) { _log "calendar: no access_token returned"; return "" }

  # 2) day window in local time (RFC3339 with offset)
  $day    = [datetime]::ParseExact($DateStr, "yyyy-MM-dd", $null)
  $offset = [System.TimeZoneInfo]::Local.GetUtcOffset($day)
  $off    = ("{0}{1:00}:{2:00}" -f ($(if ($offset.Ticks -ge 0) { "+" } else { "-" })), [math]::Abs($offset.Hours), [math]::Abs($offset.Minutes))
  $timeMin = $DateStr + "T00:00:00" + $off
  $timeMax = $DateStr + "T23:59:59" + $off

  $calId = if ($sec.calendar -and $sec.calendar.calendarId) { $sec.calendar.calendarId } else { "primary" }
  $calIdEnc = [uri]::EscapeDataString($calId)
  $qs = "singleEvents=true&orderBy=startTime&maxResults=50" +
        "&timeMin=" + [uri]::EscapeDataString($timeMin) +
        "&timeMax=" + [uri]::EscapeDataString($timeMax)
  $url = "https://www.googleapis.com/calendar/v3/calendars/$calIdEnc/events?$qs"

  try {
    $resp = Invoke-RestMethod -Uri $url -Headers @{ Authorization = "Bearer $access" } -TimeoutSec 20
  } catch {
    _log ("calendar: events.list failed ({0})" -f $_.Exception.Message)
    return ""
  }

  $items = @($resp.items | Where-Object { $_.status -ne "cancelled" })
  if ($items.Count -eq 0) { _log "calendar: 0 events today"; return "" }

  $sb = New-Object System.Text.StringBuilder
  foreach ($e in $items) {
    $summary = if ($e.summary) { $e.summary } else { "(untitled)" }
    if ($e.start.dateTime) {
      $st = ([datetime]$e.start.dateTime).ToString("HH:mm")
      $en = if ($e.end.dateTime) { ([datetime]$e.end.dateTime).ToString("HH:mm") } else { "" }
      $when = if ($en) { "$st-$en" } else { $st }
      [void]$sb.AppendLine(("- {0}  {1}" -f $when, $summary))
    } else {
      [void]$sb.AppendLine(("- all-day  {0}" -f $summary))
    }
  }
  _log ("calendar: {0} events collected" -f $items.Count)
  return $sb.ToString().TrimEnd()
}
