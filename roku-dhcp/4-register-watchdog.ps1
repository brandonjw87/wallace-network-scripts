# RUN AS ADMIN. Runs healthcheck every 5 min as SYSTEM.
$a=New-ScheduledTaskAction -Execute powershell.exe -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$PSScriptRoot\3-healthcheck.ps1`""
$t=New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5)
Register-ScheduledTask -TaskName 'roku-dhcp-watchdog' -Action $a -Trigger $t -User SYSTEM -RunLevel Highest -Force
