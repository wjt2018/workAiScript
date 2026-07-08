<#
  register-monthly-task.ps1
  Register (or refresh) the Windows Scheduled Task that runs the monthly report
  at 18:10 on the LAST day of every month -- after the daily report (17:50) and,
  when that day is a Friday, the weekly report (18:00) have finished.

  New-ScheduledTaskTrigger cannot express "last day of month", so the task is
  created with schtasks.exe (/SC MONTHLY /MO LASTDAY), then its settings are
  patched via Set-ScheduledTask (StartWhenAvailable, 15-min limit).
  Runs as the current user, only when logged on.
#>
$ErrorActionPreference = "Stop"

$Root       = Split-Path -Parent $MyInvocation.MyCommand.Path
$scriptPath = Join-Path $Root "monthly-report.ps1"
$taskName   = "WorkAiMonthlyReport"

$tr = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $scriptPath"

& schtasks.exe /Create /F /TN $taskName /TR $tr /SC MONTHLY /MO LASTDAY /M * /ST 18:10 | Out-Null
if ($LASTEXITCODE -ne 0) { throw "schtasks /Create failed (exit $LASTEXITCODE)" }

# StartWhenAvailable: if the PC was off at 18:10, run as soon as it's back on.
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 15) -MultipleInstances IgnoreNew
Set-ScheduledTask -TaskName $taskName -Settings $settings | Out-Null

Write-Output "Registered scheduled task '$taskName' (last day of every month, 18:10)."
Get-ScheduledTask -TaskName $taskName | Format-List TaskName, State
(Get-ScheduledTask -TaskName $taskName | Get-ScheduledTaskInfo).NextRunTime
