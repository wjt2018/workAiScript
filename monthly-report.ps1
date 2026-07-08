<#
  monthly-report.ps1
  Merge this month's weekly reports (reports/week-yyyy-MM-dd.md) -- plus any
  leftover daily reports (reports/yyyy-MM-dd.md) from a last partial week that
  was never rolled into a weekly -- into ONE monthly report via headless
  `claude -p`, save it as reports/month-yyyy-MM.md, DM it to me on Slack, then
  DELETE the source files that were merged.

  Safety: if claude fails, the raw concatenation is saved instead and the
  source files are KEPT, so you can re-run later.

  Kept ASCII-only on purpose (Chinese/format lives in prompt-template-month.txt).

  Usage:
    powershell -NoProfile -ExecutionPolicy Bypass -File monthly-report.ps1
    powershell ... -File monthly-report.ps1 -Month 2026-06    # backfill a month
    powershell ... -File monthly-report.ps1 -KeepSource      # do not delete sources
#>
param(
  [string]$Month = "",
  [switch]$KeepSource
)

$ErrorActionPreference = "Stop"

# Force UTF-8 everywhere so the prompt piped to claude survives on zh-CN boxes.
$OutputEncoding = New-Object System.Text.UTF8Encoding $false
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch {}
try { [Console]::InputEncoding  = New-Object System.Text.UTF8Encoding $false } catch {}

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path

if ($Month) { $first = [datetime]::ParseExact($Month + "-01", "yyyy-MM-dd", $null) }
else        { $d = Get-Date; $first = New-Object datetime($d.Year, $d.Month, 1) }
$monthStr = $first.ToString("yyyy-MM")

$reportsDir = Join-Path $Root "reports"
$logsDir    = Join-Path $Root "logs"
New-Item -ItemType Directory -Force -Path $reportsDir | Out-Null
New-Item -ItemType Directory -Force -Path $logsDir    | Out-Null
$logFile = Join-Path $logsDir ("month-" + $monthStr + ".log")

function Log($msg) {
  $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $msg
  Add-Content -Path $logFile -Value $line -Encoding utf8
  Write-Output $line
}

Log "=== monthly report run for $monthStr ==="

# ---- collect this month's weekly reports + leftover daily reports ----
$weekFiles  = @()
$dailyFiles = @()
foreach ($f in (Get-ChildItem $reportsDir -File)) {
  $m = [regex]::Match($f.Name, '^week-(\d{4}-\d{2}-\d{2})\.md$')
  if ($m.Success -and $m.Groups[1].Value.StartsWith($monthStr)) { $weekFiles += $f; continue }
  $m = [regex]::Match($f.Name, '^(\d{4}-\d{2}-\d{2})\.md$')
  if ($m.Success -and $m.Groups[1].Value.StartsWith($monthStr)) { $dailyFiles += $f }
}
$weekFiles  = @($weekFiles  | Sort-Object Name)
$dailyFiles = @($dailyFiles | Sort-Object Name)
$srcFiles   = @($weekFiles) + @($dailyFiles)

if ($srcFiles.Count -eq 0) {
  Log "no weekly or daily reports found for $monthStr; nothing to merge"
  Write-Output "No reports found for $monthStr. Nothing to do."
  return
}
Log ("found {0} weekly + {1} leftover daily report(s): {2}" -f `
  $weekFiles.Count, $dailyFiles.Count, (($srcFiles | ForEach-Object { $_.Name }) -join ", "))

# ---- build merged digest ----
$sb = New-Object System.Text.StringBuilder
foreach ($f in $weekFiles) {
  [void]$sb.AppendLine("## weekly report: $($f.BaseName)")
  [void]$sb.AppendLine((Get-Content $f.FullName -Raw -Encoding utf8).Trim())
  [void]$sb.AppendLine("")
}
foreach ($f in $dailyFiles) {
  [void]$sb.AppendLine("## leftover daily report (not yet in a weekly): $($f.BaseName)")
  [void]$sb.AppendLine((Get-Content $f.FullName -Raw -Encoding utf8).Trim())
  [void]$sb.AppendLine("")
}
$digest = $sb.ToString().Trim()

# ---- build prompt from UTF-8 template ----
$tpl = Get-Content (Join-Path $Root "prompt-template-month.txt") -Raw -Encoding utf8
$prompt = $tpl.Replace("{{MONTH}}", $monthStr).Replace("{{REPORTS}}", $digest)

Log "calling claude to consolidate the month..."
$claudeOk = $true
$report = $prompt | & claude -p 2>>$logFile
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($report)) {
  Log ("claude failed or empty (exit {0}); saving raw digest, keeping source files" -f $LASTEXITCODE)
  $claudeOk = $false
  $report = "This Month: (raw weekly/daily reports; claude unavailable)`r`n`r`n" + $digest
}

# claude -p returns a string[] (one item per line); flatten to a single string.
$report = (@($report) -join "`r`n").TrimEnd()

$outPath = Join-Path $reportsDir ("month-" + $monthStr + ".md")
Set-Content -Path $outPath -Value $report -Encoding utf8
Log "saved monthly report: $outPath"

# ---- deliver to me as a Slack DM (skips silently if bot token not set) ----
. (Join-Path $Root "send-slack.ps1")
Send-SlackReport -Text $report -Root $Root -Logger ${function:Log} | Out-Null

# ---- delete the merged source files (only if claude actually consolidated them) ----
if ($claudeOk -and -not $KeepSource) {
  foreach ($f in $srcFiles) {
    Remove-Item $f.FullName -Force -Confirm:$false
    Log ("deleted source report: " + $f.Name)
  }
} elseif (-not $claudeOk) {
  Log "source files kept (claude failed); re-run monthly-report.ps1 later to retry"
} else {
  Log "source files kept (-KeepSource)"
}

Write-Output ""
Write-Output "==== monthly report saved: $outPath ===="
Write-Output $report
