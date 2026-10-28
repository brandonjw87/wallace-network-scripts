# RUN AS ADMIN. Pins the PC to 192.0.2.28 (static) on Wi-Fi, DNS -> itself. Saves prior state for rollback.
$ErrorActionPreference='Stop'; $if='Wi-Fi'; $d=$PSScriptRoot
Get-NetIPConfiguration -InterfaceAlias $if | Out-File "$d\backup-ipconfig.txt"
Get-DnsClientServerAddress -InterfaceAlias $if | Out-File -Append "$d\backup-ipconfig.txt"
Set-NetIPInterface -InterfaceAlias $if -Dhcp Disabled
Get-NetIPAddress -InterfaceAlias $if -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false
Remove-NetRoute -InterfaceAlias $if -DestinationPrefix 0.0.0.0/0 -Confirm:$false -ErrorAction SilentlyContinue
New-NetIPAddress -InterfaceAlias $if -IPAddress 192.0.2.28 -PrefixLength 24 -DefaultGateway 192.0.2.15
Set-DnsClientServerAddress -InterfaceAlias $if -ServerAddresses 127.0.0.1,192.0.2.15
Test-Connection 192.0.2.15 -Count 2; Resolve-DnsName example.com -Server 127.0.0.1
