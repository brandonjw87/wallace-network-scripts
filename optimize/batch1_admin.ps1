# Batch 1 (machine-level, ADMIN). Keeps High performance plan; on AC: never sleep, no PCIe ASPM, no USB selective suspend, no disk spin-down, min CPU state 5% (lets it cool; max stays 100%). Display off after 10 min. Fast Startup off (Hiberboot is already inert because hibernation is disabled; this just makes it explicit). No reboot needed except Fast Startup takes effect at next shutdown.
. "$PSScriptRoot\_common.ps1"; Assert-Admin
$bk=Init-Backup 'batch1_admin'
if($bk.First){ powercfg /getactivescheme | Set-Content "$($bk.Dir)\activescheme.txt"; powercfg /query SCHEME_CURRENT | Set-Content "$($bk.Dir)\powercfg_query.txt" }
Backup-Keys $bk @('HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power')
Finish-Backup $bk
powercfg /setactive SCHEME_MIN
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
powercfg /change monitor-timeout-ac 10
powercfg /change disk-timeout-ac 0
powercfg /setacvalueindex SCHEME_CURRENT SUB_PCIEXPRESS ASPM 0
powercfg /setacvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0
powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN 5
powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100
powercfg /setactive SCHEME_CURRENT
Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' HiberbootEnabled 0
Write-Host 'Done.'
