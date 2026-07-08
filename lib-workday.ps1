<#
  lib-workday.ps1
  Decide whether a given date is a Chinese working day, honouring official
  public holidays AND tiaoxiu makeup workdays (when a Sat/Sun becomes a workday).

  Data source: holiday-cn (official State Council schedule, community-maintained).
    https://raw.githubusercontent.com/NateScarlet/holiday-cn/master/<year>.json
  Each listed day has isOffDay: true (holiday/off) or false (makeup workday/on).
  Days NOT listed follow the normal rule: Mon-Fri = work, Sat/Sun = off.

  Cached per-year under cache/holiday-<year>.json so we don't hit the network
  on every run and still work offline (falls back to Mon-Fri if never fetched).

  Dot-source this file, then call:  Test-ChineseWorkday -Day (Get-Date)
#>

function Test-ChineseWorkday {
  param(
    [Parameter(Mandatory = $true)][datetime]$Day,
    [string]$Root = (Split-Path -Parent $MyInvocation.MyCommand.Path),
    [scriptblock]$Logger = $null
  )

  function _log($m) { if ($Logger) { & $Logger $m } }

  $year     = $Day.Year
  $dateStr  = $Day.ToString("yyyy-MM-dd")
  $isWeekend = ($Day.DayOfWeek -eq [DayOfWeek]::Saturday) -or ($Day.DayOfWeek -eq [DayOfWeek]::Sunday)

  $cacheDir  = Join-Path $Root "cache"
  New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
  $cacheFile = Join-Path $cacheDir ("holiday-{0}.json" -f $year)
  $url       = "https://raw.githubusercontent.com/NateScarlet/holiday-cn/master/$year.json"

  $data = $null

  # refresh cache if missing or older than 20 days
  $needFetch = $true
  if (Test-Path $cacheFile) {
    $ageDays = ((Get-Date) - (Get-Item $cacheFile).LastWriteTime).TotalDays
    if ($ageDays -lt 20) { $needFetch = $false }
  }

  if ($needFetch) {
    try {
      $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 12
      $resp.Content | Set-Content -Path $cacheFile -Encoding utf8
      _log "workday: fetched holiday data for $year"
    } catch {
      _log ("workday: fetch failed ({0}); using cache if present" -f $_.Exception.Message)
    }
  }

  if (Test-Path $cacheFile) {
    try { $data = Get-Content $cacheFile -Raw -Encoding utf8 | ConvertFrom-Json } catch { $data = $null }
  }

  if ($null -eq $data -or $null -eq $data.days) {
    # no data at all: fall back to plain weekday rule
    $work = -not $isWeekend
    return [pscustomobject]@{
      IsWorkday = $work
      Reason    = if ($work) { "workday (Mon-Fri default; no holiday data)" } else { "weekend (no holiday data)" }
    }
  }

  $entry = $data.days | Where-Object { $_.date -eq $dateStr } | Select-Object -First 1
  if ($entry) {
    if ($entry.isOffDay) {
      return [pscustomobject]@{ IsWorkday = $false; Reason = ("holiday: {0}" -f $entry.name) }
    } else {
      return [pscustomobject]@{ IsWorkday = $true;  Reason = ("makeup workday (for {0})" -f $entry.name) }
    }
  }

  # not a special day: normal weekday rule
  $work = -not $isWeekend
  return [pscustomobject]@{
    IsWorkday = $work
    Reason    = if ($work) { "normal workday" } else { "weekend" }
  }
}
