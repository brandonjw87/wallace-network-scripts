# Batch 2 (machine-level, ADMIN). DiagTrack -> Manual+stopped; telemetry policy = Required(1, minimum on Home); Delivery Optimization = HTTP only (no peer upload); MapsBroker -> Manual; Windows Error Reporting & feedback prompts off; SoftLanding (tips) task disabled. No reboot needed.
# Does NOT touch: SysMain, WSearch, Spooler, icssvc, SharedAccess, AdGuardHome, Defender, Windows Update.
. "$PSScriptRoot\_common.ps1"; Assert-Admin
$bk=Init-Backup 'batch2_admin'
Backup-Services $bk @('DiagTrack','MapsBroker','dmwappushservice')
Backup-Keys $bk @('HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection','HKLM\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization','HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting')
if($bk.First){ Get-ScheduledTask -TaskName SoftLandingCreativeManagementTask -ea 0 | select TaskPath,TaskName,@{n='State';e={$_.State.ToString()}} | ConvertTo-Json | Set-Content "$($bk.Dir)\tasks.json" }
Finish-Backup $bk
Stop-Service DiagTrack -Force -ea 0; Set-Service DiagTrack -StartupType Manual
Set-Service MapsBroker -StartupType Manual
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' AllowTelemetry 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' DoNotShowFeedbackNotifications 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' DODownloadMode 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting' Disabled 1
Get-ScheduledTask -TaskName SoftLandingCreativeManagementTask -ea 0 | Disable-ScheduledTask | Out-Null
Write-Host 'Done.'
