<#
  weekly-report.ps1
  Merge this week's daily reports (reports/yyyy-MM-dd.md, Monday..today) into
  ONE weekly report via headless `claude -p`, save it as reports/week-<friday>.md,
  DM it to me on Slack, then DELETE the daily report files that were merged.

  Safety: if claude fails, the raw concatenation is saved instead and the daily
  files are KEPT (so nothing is lost and you can re-run with -Force later).

  Kept ASCII-only on purpose (Chinese/format lives in prompt-template-week.txt).

  Usage:
    powershell -NoProfile -ExecutionPolicy Bypass -File weekly-report.ps1
    powershell ... -File weekly-report.ps1 -Date 2026-07-10   # treat this day as "Friday"
    powershell ... -File weekly-report.ps1 -KeepDaily         # do not delete daily files
#>
param(
  [string]$Date = "",
  [switch]$KeepDaily
)

$ErrorActionPreference = "Stop"

# Force UTF-8 everywhere so the prompt piped to claude survives on zh-CN boxes.
$OutputEncoding = New-Object System.Text.UTF8Encoding $false
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch {}
try { [Console]::InputEncoding  = New-Object System.Text.UTF8Encoding $false } catch {}

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path

if ($Date) { $day = [datetime]::ParseExact($Date, "yyyy-MM-dd", $null) } else { $day = Get-Date }
$dayStr = $day.ToString("yyyy-MM-dd")

# Monday of the week containing $day
$monday = $day.AddDays(-((([int]$day.DayOfWeek) + 6) % 7)).Date
$monStr = $monday.ToString("yyyy-MM-dd")

$reportsDir = Join-Path $Root "reports"
$logsDir    = Join-Path $Root "logs"
New-Item -ItemType Directory -Force -Path $reportsDir | Out-Null
New-Item -ItemType Directory -Force -Path $logsDir    | Out-Null
$logFile = Join-Path $logsDir ("week-" + $dayStr + ".log")

function Log($msg) {
  $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $msg
  Add-Content -Path $logFile -Value $line -Encoding utf8
  Write-Output $line
}

Log "=== weekly report run for week $monStr .. $dayStr ==="

# ---- collect this week's daily report files (Monday..today, strict name match) ----
$dailyFiles = @()
$d = $monday
while ($d -le $day.Date) {
  $p = Join-Path $reportsDir ($d.ToString("yyyy-MM-dd") + ".md")
  if (Test-Path $p) { $dailyFiles += Get-Item $p }
  $d = $d.AddDays(1)
}

if ($dailyFiles.Count -eq 0) {
  Log "no daily reports found for this week; nothing to merge"
  Write-Output "No daily reports found between $monStr and $dayStr. Nothing to do."
  return
}
Log ("found {0} daily report(s): {1}" -f $dailyFiles.Count, (($dailyFiles | ForEach-Object { $_.Name }) -join ", "))

# ---- build merged digest (one section per day) ----
$sb = New-Object System.Text.StringBuilder
foreach ($f in $dailyFiles) {
  $dateName = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
  $dow = [datetime]::ParseExact($dateName, "yyyy-MM-dd", $null).DayOfWeek
  [void]$sb.AppendLine("## $dateName ($dow)")
  [void]$sb.AppendLine((Get-Content $f.FullName -Raw -Encoding utf8).Trim())
  [void]$sb.AppendLine("")
}
$digest = $sb.ToString().Trim()

# ---- build prompt from UTF-8 template ----
$tpl = Get-Content (Join-Path $Root "prompt-template-week.txt") -Raw -Encoding utf8
$prompt = $tpl.Replace("{{WEEK_RANGE}}", "$monStr to $dayStr").Replace("{{REPORTS}}", $digest)

Log "calling claude to consolidate the week..."
$claudeOk = $true
$report = $prompt | & claude -p 2>>$logFile
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($report)) {
  Log ("claude failed or empty (exit {0}); saving raw digest, keeping daily files" -f $LASTEXITCODE)
  $claudeOk = $false
  $report = "This Week: (raw daily reports; claude unavailable)`r`n`r`n" + $digest
}

# claude -p returns a string[] (one item per line); flatten to a single string.
$report = (@($report) -join "`r`n").TrimEnd()

$outPath = Join-Path $reportsDir ("week-" + $dayStr + ".md")
Set-Content -Path $outPath -Value $report -Encoding utf8
Log "saved weekly report: $outPath"

# ---- deliver to me as a Slack DM (skips silently if bot token not set) ----
. (Join-Path $Root "send-slack.ps1")
Send-SlackReport -Text $report -Root $Root -Logger ${function:Log} | Out-Null

# ---- delete the merged daily files (only if claude actually consolidated them) ----
if ($claudeOk -and -not $KeepDaily) {
  foreach ($f in $dailyFiles) {
    Remove-Item $f.FullName -Force -Confirm:$false
    Log ("deleted daily report: " + $f.Name)
  }
} elseif (-not $claudeOk) {
  Log "daily files kept (claude failed); re-run weekly-report.ps1 later to retry"
} else {
  Log "daily files kept (-KeepDaily)"
}

Write-Output ""
Write-Output "==== weekly report saved: $outPath ===="
Write-Output $report
