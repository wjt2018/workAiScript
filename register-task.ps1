<#
  register-task.ps1
  Register (or refresh) the Windows Scheduled Task that runs the daily report
  every day at 18:00 local time. The script itself decides whether today is a
  Chinese working day (skips public holidays, runs on tiaoxiu makeup Saturdays),
  so the trigger fires daily and the workday logic lives in one place.
  Runs as the current user, only when logged on (no stored password needed).
#>
$ErrorActionPreference = "Stop"

$Root       = Split-Path -Parent $MyInvocation.MyCommand.Path
$scriptPath = Join-Path $Root "daily-report.ps1"
$taskName   = "WorkAiDailyReport"

$action = New-ScheduledTaskAction -Execute "powershell.exe" `
  -Argument ("-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"{0}`"" -f $scriptPath)

$trigger = New-ScheduledTaskTrigger -Daily -At 18:00

# StartWhenAvailable: if the PC was off at 18:00, run as soon as it's back on.
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 15) -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $taskName `
  -Action $action -Trigger $trigger -Settings $settings `
  -Description "Generate my work daily report (git + calendar + slack) at 18:00 daily; skips non-workdays." `
  -Force | Out-Null

Write-Output "Registered scheduled task '$taskName' (daily 18:00; script skips non-workdays)."
Get-ScheduledTask -TaskName $taskName | Format-List TaskName, State
(Get-ScheduledTask -TaskName $taskName | Get-ScheduledTaskInfo).NextRunTime
