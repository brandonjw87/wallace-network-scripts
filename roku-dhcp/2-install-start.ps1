# RUN AS ADMIN. Firewall + install dhcpsrv as a service. Expects dhcpsrv.exe extracted into this folder.
$ErrorActionPreference='Stop'; $d=$PSScriptRoot; Set-Location $d
if(!(Test-Path "$d\dhcpsrv.exe")){throw "Download dhcpsrv from https://www.dhcpserver.de/cms/download/ and extract dhcpsrv.exe here"}
New-NetFirewallRule -DisplayName 'roku-dhcp UDP67' -Direction Inbound -Protocol UDP -LocalPort 67 -Action Allow -Profile Private
New-NetFirewallRule -DisplayName 'roku-dhcp DNS53' -Direction Inbound -Protocol UDP -LocalPort 53 -Action Allow -Profile Private
New-NetFirewallRule -DisplayName 'roku-dhcp DNS53tcp' -Direction Inbound -Protocol TCP -LocalPort 53 -Action Allow -Profile Private
.\dhcpsrv.exe -install; .\dhcpsrv.exe -start
Start-Sleep 3; Get-Service DHCPServer -ErrorAction SilentlyContinue; netstat -ano | findstr ":67 "
