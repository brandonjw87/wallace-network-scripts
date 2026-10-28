# RUN AS ADMIN. Restores everything: stops/removes dhcpsrv, removes firewall rules, watchdog task, returns Wi-Fi to DHCP.
$d=$PSScriptRoot; Set-Location $d; $if='Wi-Fi'
if(Test-Path .\dhcpsrv.exe){ .\dhcpsrv.exe -stop; .\dhcpsrv.exe -remove }
Get-NetFirewallRule -DisplayName 'roku-dhcp*' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
Unregister-ScheduledTask -TaskName 'roku-dhcp-watchdog' -Confirm:$false -ErrorAction SilentlyContinue
Remove-NetRoute -InterfaceAlias $if -DestinationPrefix 0.0.0.0/0 -Confirm:$false -ErrorAction SilentlyContinue
Set-NetIPInterface -InterfaceAlias $if -Dhcp Enabled
Set-DnsClientServerAddress -InterfaceAlias $if -ResetServerAddresses
ipconfig /renew "$if"; ipconfig /all
Write-Host 'Rollback done. Then: power-cycle each Roku (or Settings>Network>Check connection) so it re-leases from the Spectrum router.'
