$o='C:\Users\YOU\Tools\wallace-roku-v2\eth-dns-result.txt'
try{ Get-DnsClientServerAddress -InterfaceAlias Ethernet | Out-File 'C:\Users\YOU\Tools\wallace-roku-v2\eth-dns-before.txt'
Set-DnsClientServerAddress -InterfaceAlias Ethernet -ServerAddresses 127.0.0.1,192.0.2.15 -ea Stop
netsh interface ipv6 set dnsservers name=Ethernet source=static address=::1 validate=no | Out-Null
Clear-DnsClientCache; Restart-Service SharedAccess -Force
'OK' | Out-File $o }catch{ "ERR $_" | Out-File $o }
