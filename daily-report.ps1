<#
  daily-report.ps1
  Generate a Chinese work daily-report from today's git commits, via headless `claude -p`.
  Kept ASCII-only on purpose (Chinese lives in prompt-template.txt, read as UTF-8),
  so PowerShell 5.1 on a zh-CN box never mojibakes.

  Usage:
    powershell -NoProfile -ExecutionPolicy Bypass -File daily-report.ps1
    powershell ... -File daily-report.ps1 -Date 2026-07-06   # backfill / test a specific day
#>
param(
  [string]$Date = "",
  [switch]$Force   # bypass the Chinese-workday check (for manual/backfill runs)
)

$ErrorActionPreference = "Stop"

# Force UTF-8 everywhere so Chinese commit msgs + the prompt piped to claude survive.
$OutputEncoding = New-Object System.Text.UTF8Encoding $false
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch {}
try { [Console]::InputEncoding  = New-Object System.Text.UTF8Encoding $false } catch {}

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$cfg  = Get-Content (Join-Path $Root "config.json") -Raw -Encoding utf8 | ConvertFrom-Json

# ---- date window (local) ----
if ($Date) { $day = [datetime]::ParseExact($Date, "yyyy-MM-dd", $null) } else { $day = Get-Date }
$dayStr = $day.ToString("yyyy-MM-dd")
$since  = $day.ToString("yyyy-MM-dd") + " 00:00:00"
$until  = $day.ToString("yyyy-MM-dd") + " 23:59:59"

$reportsDir = Join-Path $Root "reports"
$logsDir    = Join-Path $Root "logs"
New-Item -ItemType Directory -Force -Path $reportsDir | Out-Null
New-Item -ItemType Directory -Force -Path $logsDir    | Out-Null
$logFile = Join-Path $logsDir ($dayStr + ".log")

function Log($msg) {
  $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $msg
  Add-Content -Path $logFile -Value $line -Encoding utf8
  Write-Output $line
}

Log "=== daily report run for $dayStr ==="

# ---- Chinese workday gate (skip holidays; run on tiaoxiu makeup days) ----
. (Join-Path $Root "lib-workday.ps1")
$wd = Test-ChineseWorkday -Day $day -Root $Root -Logger ${function:Log}
Log ("workday check: {0} -> {1}" -f $wd.Reason, $(if ($wd.IsWorkday) { "run" } else { "skip" }))
if (-not $wd.IsWorkday -and -not $Force) {
  Write-Output "Not a Chinese workday ($($wd.Reason)); skipping. Use -Force to override."
  return
}

# ---- author filter regex ----
$terms = @()
$terms += $cfg.authorEmails
$terms += $cfg.authorNames
$authorRegex = ($terms | Where-Object { $_ } | ForEach-Object { [regex]::Escape($_) }) -join "|"

# ---- collect local commits ----
$sb = New-Object System.Text.StringBuilder
$totalCommits = 0
$reposWithCommits = @{}

foreach ($repo in $cfg.repos) {
  if (-not (Test-Path (Join-Path $repo ".git"))) { Log "skip (not a git repo): $repo"; continue }
  $fmt = "%h|%an|%ae|%ad|%s"
  $out = & git -C $repo log --all --no-merges "--since=$since" "--until=$until" "--date=format:%H:%M" "--pretty=format:$fmt" 2>$null
  if (-not $out) { continue }
  $matched = @($out | Where-Object { $_ -match $authorRegex })
  if ($matched.Count -eq 0) { continue }

  $repoName = Split-Path $repo -Leaf
  $reposWithCommits[$repoName] = $true
  [void]$sb.AppendLine("## repo: $repoName")
  foreach ($l in $matched) {
    $p = $l -split "\|", 5
    [void]$sb.AppendLine(("- {0}  {1}" -f $p[3], $p[4]))
  }
  [void]$sb.AppendLine("")
  $totalCommits += $matched.Count
  Log ("repo {0}: {1} commits" -f $repoName, $matched.Count)
}

# ---- supplement: pushed commits across GitHub via gh ----
if ($cfg.useGhSearch) {
  try {
    $ghRaw = & gh search commits --author "@me" --committer-date $dayStr --limit 50 --json "repository,commit" 2>$null
    if ($ghRaw) {
      $ghItems = $ghRaw | ConvertFrom-Json
      $extra = @($ghItems | Where-Object { -not $reposWithCommits[$_.repository.name] })
      if ($extra.Count -gt 0) {
        [void]$sb.AppendLine("## GitHub (pushed, other repos)")
        foreach ($it in $extra) {
          $msg = ($it.commit.message -split "`n")[0]
          [void]$sb.AppendLine(("- [{0}] {1}" -f $it.repository.name, $msg))
          $totalCommits += 1
        }
        [void]$sb.AppendLine("")
        Log ("gh search added {0} commits from other repos" -f $extra.Count)
      }
    }
  } catch { Log ("gh search failed (skipped): {0}" -f $_.Exception.Message) }
}

$commits = $sb.ToString().Trim()
$outPath = Join-Path $reportsDir ($dayStr + ".md")

# ---- extra sources: Google Calendar + Slack (silently skip if unconfigured) ----
. (Join-Path $Root "collect-calendar.ps1")
. (Join-Path $Root "collect-slack.ps1")
$calendar = Get-CalendarDigest -DateStr $dayStr -Root $Root -Logger ${function:Log}
$slack    = Get-SlackDigest    -DateStr $dayStr -Root $Root -Logger ${function:Log}

if ([string]::IsNullOrWhiteSpace($commits) -and
    [string]::IsNullOrWhiteSpace($calendar) -and
    [string]::IsNullOrWhiteSpace($slack)) {
  Log "no data from any source today"
  Set-Content -Path $outPath -Value ("Today:`r`n- (no activity detected today)") -Encoding utf8
  Write-Output "No data today. Wrote placeholder: $outPath"
  return
}

Log ("data collected (commits={0}); calling claude..." -f $totalCommits)

# ---- build prompt from UTF-8 template ----
$none = "(none)"
$tpl = Get-Content (Join-Path $Root "prompt-template.txt") -Raw -Encoding utf8
$prompt = $tpl.Replace("{{DATE}}", $dayStr).
  Replace("{{COMMITS}}",  $(if ($commits)  { $commits }  else { $none })).
  Replace("{{CALENDAR}}", $(if ($calendar) { $calendar } else { $none })).
  Replace("{{SLACK}}",    $(if ($slack)    { $slack }    else { $none }))

# ---- headless claude ----
$report = $prompt | & claude -p 2>>$logFile
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($report)) {
  Log ("claude failed or empty (exit {0}); saving raw digest instead" -f $LASTEXITCODE)
  $fb = New-Object System.Text.StringBuilder
  [void]$fb.AppendLine("# Daily Report $dayStr (raw data; claude unavailable)")
  if ($commits)  { [void]$fb.AppendLine("`r`n## Commits`r`n$commits") }
  if ($calendar) { [void]$fb.AppendLine("`r`n## Calendar`r`n$calendar") }
  if ($slack)    { [void]$fb.AppendLine("`r`n## Slack`r`n$slack") }
  $report = $fb.ToString()
}

# claude -p returns a string[] (one item per line); flatten to a single string.
$report = (@($report) -join "`r`n").TrimEnd()

Set-Content -Path $outPath -Value $report -Encoding utf8
Log "saved report: $outPath"

# ---- deliver to me as a Slack DM (skips silently if bot token not set) ----
. (Join-Path $Root "send-slack.ps1")
Send-SlackReport -Text $report -Root $Root -Logger ${function:Log} | Out-Null

Write-Output ""
Write-Output "==== report saved: $outPath ===="
Write-Output $report
