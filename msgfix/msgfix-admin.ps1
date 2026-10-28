$ErrorActionPreference='Continue'; $log='C:\Users\YOU\Tools\msgfix\msgfix-admin.log'
function L($m){ $l="$(Get-Date -f s) $m"; Add-Content $log $l }
L '=== msgfix-admin start'
$bk=(Get-Content C:\Users\YOU\Tools\msgfix\bkdir.txt).Trim(); $y='C:\Users\YOU\Tools\AdGuardHome\AdGuardHome.yaml'
try { Copy-Item $y "$bk\AdGuardHome.yaml"; icacls "$bk\AdGuardHome.yaml" /inheritance:r /grant:r "*S-1-5-32-544:F" "SYSTEM:F" | Out-Null; L 'yaml backed up (admin-only ACL, not printed)' } catch { L "yaml backup FAILED $_"; exit 1 }
reg export HKLM\SYSTEM\CurrentControlSet\Services\SharedAccess "$bk\SharedAccess.reg" /y | Out-Null; reg export HKLM\SYSTEM\CurrentControlSet\Services\IKEEXT "$bk\IKEEXT.reg" /y | Out-Null
netsh advfirewall export "$bk\firewall.wfw" | Out-Null; L 'SharedAccess/IKEEXT registry + firewall policy exported'
# Show only the dns bind/port lines (no secrets live there)
$t=[IO.File]::ReadAllText($y); $m=[regex]::Match($t,'(?m)^  bind_hosts:\r?\n((?:    - .*\r?\n)+)'); L ("current bind_hosts: " + ($m.Groups[1].Value -replace '\s+',' '))
# IKEEXT on this PC holds UDP 500/4500; phones' Wi-Fi Calling IPsec (IKE/NAT-T) must NAT through ICS on those ports.
$ik=Get-Service IKEEXT; L "IKEEXT before: $($ik.Status) $($ik.StartType)"; Set-Service IKEEXT -StartupType Manual; Stop-Service IKEEXT -Force -ErrorAction SilentlyContinue; Start-Sleep 2; L "IKEEXT after: $((Get-Service IKEEXT).Status) $((Get-Service IKEEXT).StartType)"
L ("udp 500/4500 owners now: " + ((netstat -ano -p udp | Select-String ':500 |:4500 ') -join ' | '))
# DNS bind guard install
$pd='C:\ProgramData\WALLACE Admin'; New-Item -ItemType Directory -Force $pd | Out-Null; Copy-Item C:\Users\YOU\Tools\msgfix\dns-bind-guard.ps1 "$pd\dns-bind-guard.ps1" -Force
icacls $pd /inheritance:r /grant:r "*S-1-5-32-544:(OI)(CI)F" "SYSTEM:(OI)(CI)F" "*S-1-5-32-545:(OI)(CI)RX" | Out-Null
& powershell -NoProfile -ExecutionPolicy Bypass -File "$pd\dns-bind-guard.ps1" -Force
L ("guard log tail: " + ((Get-Content "$pd\dns-bind-guard.log" -Tail 4) -join ' | '))
L ("udp 53 listeners: " + ((netstat -ano -p udp | Select-String ':53 ') -join ' | '))
$ok=$false; try { Resolve-DnsName example.com -Server 192.0.2.11 -DnsOnly -ErrorAction Stop | Out-Null; $ok=$true } catch {}; L "resolve via 192.0.2.11: $ok"
$ok2=$false; try { Resolve-DnsName example.com -Server 127.0.0.1 -DnsOnly -ErrorAction Stop | Out-Null; $ok2=$true } catch {}; L "resolve via 127.0.0.1: $ok2"
if (-not $ok2) { L 'ROLLBACK: restoring yaml backup'; Copy-Item "$bk\AdGuardHome.yaml" $y -Force; Restart-Service AdGuardHome -Force; Start-Sleep 5; L "after rollback svc=$((Get-Service AdGuardHome).Status)" }
else {
  $act=New-ScheduledTaskAction -Execute powershell.exe -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$pd\dns-bind-guard.ps1`""
  $tr1=New-ScheduledTaskTrigger -AtStartup; $tr2=New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 2)
  Register-ScheduledTask -TaskPath '\WALLACE\' -TaskName 'DNS bind guard' -Action $act -Trigger $tr1,$tr2 -User SYSTEM -RunLevel Highest -Settings (New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 3)) -Force | Out-Null; L 'scheduled task \WALLACE\DNS bind guard installed' }
L '=== msgfix-admin done'
