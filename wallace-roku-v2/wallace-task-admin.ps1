Start-Transcript 'C:\Users\YOU\Tools\dev-config-backup\pre-wallace-20261027-002106\admin-yaml-task.log' -Force
Copy-Item 'C:\Users\YOU\Tools\AdGuardHome\AdGuardHome.yaml' 'C:\Users\YOU\Tools\dev-config-backup\pre-wallace-20261027-002106\AdGuardHome.yaml' -Force
$acl = Get-Acl 'C:\Users\YOU\Tools\dev-config-backup\pre-wallace-20261027-002106\AdGuardHome.yaml'; 'yaml backed up: ' + (Test-Path 'C:\Users\YOU\Tools\dev-config-backup\pre-wallace-20261027-002106\AdGuardHome.yaml')
$x = [IO.File]::ReadAllText('C:\Users\YOU\Tools\dev-config-backup\pre-wallace-20261027-002106\task-watchdog.xml')
Register-ScheduledTask -TaskName 'WALLACE Watchdog' -Xml $x -Force | Out-Null
Disable-ScheduledTask -TaskName 'Wallace-Roku Watchdog' | Out-Null
Get-ScheduledTask | ? TaskName -match 'Watchdog' | ft TaskName,State -auto
Stop-Transcript
