<#
  register-weekly-task.ps1
  Register (or refresh) the Windows Scheduled Task that runs the weekly report
  every Friday at 18:02 local time -- after the Friday daily report (18:00) has
  finished, so Friday's report is included in the merge. Runs as the current
  user, only when logged on.
#>
$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$scriptPath = Join-Path $Root "weekly-report.ps1"
$taskName = "WorkAiWeeklyReport"

$action = New-ScheduledTaskAction -Execute "powershell.exe" `
  -Argument ("-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"{0}`"" -f $scriptPath)

$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Friday -At 18:02

# StartWhenAvailable: if the PC was off Friday 18:02, run as soon as it's back on.
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 15) -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $taskName `
  -Action $action -Trigger $trigger -Settings $settings `
  -Description "Merge this week's daily reports into one weekly report, DM it on Slack, delete the merged daily files. Fridays 18:02." `
  -Force | Out-Null

Write-Output "Registered scheduled task '$taskName' (Fridays 18:02)."
Get-ScheduledTask -TaskName $taskName | Format-List TaskName, State
(Get-ScheduledTask -TaskName $taskName | Get-ScheduledTaskInfo).NextRunTime
