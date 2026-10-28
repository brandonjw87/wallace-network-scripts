$log='C:\Users\YOU\Tools\encdns-admin-log.txt'; Start-Transcript $log -Force
try{
 foreach($ip in '9.9.9.9','149.112.112.112'){ Set-DnsClientDohServerAddress -ServerAddress $ip -DohTemplate 'https://dns.quad9.net/dns-query' -AutoUpgrade $true -AllowFallbackToUdp $false }
 foreach($i in 'Ethernet','Wi-Fi'){ Set-DnsClientServerAddress -InterfaceAlias $i -ServerAddresses 127.0.0.1,9.9.9.9 }
 Clear-DnsClientCache; Start-Sleep 2
 $ok=$true; try{ Resolve-DnsName example.com -EA Stop|Out-Null }catch{ $ok=$false }
 if(-not $ok){ foreach($i in 'Ethernet','Wi-Fi'){ Set-DnsClientServerAddress -InterfaceAlias $i -ServerAddresses 127.0.0.1,192.0.2.15 }; 'ROLLED BACK' } else { 'OK' }
 Get-DnsClientServerAddress -AddressFamily IPv4|? ServerAddresses|ft InterfaceAlias,ServerAddresses|Out-String
 Get-DnsClientDohServerAddress -ServerAddress 9.9.9.9|Out-String
}catch{ "ERR $_" }
Stop-Transcript
