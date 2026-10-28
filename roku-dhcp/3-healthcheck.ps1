# Health check / watchdog. Run manually, or register (admin): 4-register-watchdog.ps1. Logs to watchdog.log, pops a toast/msg on failure.
$d=$PSScriptRoot; $p=@()
try{ Resolve-DnsName example.com -Server 192.0.2.28 -DnsOnly -QuickTimeout -ErrorAction Stop | Out-Null }catch{ $p+='AdGuard DNS on 192.0.2.28:53 not answering' }
if((Get-Service AdGuardHome -ErrorAction SilentlyContinue).Status -ne 'Running'){ $p+='AdGuardHome service not running' }
$s=Get-Service DHCPServer -ErrorAction SilentlyContinue; if($s -and $s.Status -ne 'Running'){ $p+='dhcpsrv service not running' }
if(-not (Get-NetIPAddress -IPAddress 192.0.2.28 -ErrorAction SilentlyContinue)){ $p+='PC no longer has 192.0.2.28' }
if(-not (Test-Connection 192.0.2.15 -Count 1 -Quiet)){ $p+='Gateway 192.0.2.15 unreachable' }
$ts=Get-Date -f s
if($p){ "$ts FAIL: $($p -join '; ')" | Add-Content "$d\watchdog.log"; msg * "roku-dhcp: $($p -join '; ')" 2>$null; Start-Service AdGuardHome,DHCPServer -ErrorAction SilentlyContinue; exit 1 }
"$ts OK" | Add-Content "$d\watchdog.log"; exit 0
