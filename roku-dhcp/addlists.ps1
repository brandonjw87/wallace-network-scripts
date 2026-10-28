$t=Get-Content 'C:\Users\YOU\Tools\AdGuardHome\ADMIN-LOGIN.txt'
$u=($t|sls -Pattern '(?i)user\w*\s*[:=]\s*(\S+)').Matches[0].Groups[1].Value
$p=($t|sls -Pattern '(?i)pass\w*\s*[:=]\s*(\S+)').Matches[0].Groups[1].Value
$h=@{Authorization='Basic '+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($u+':'+$p))}
$have=(Invoke-RestMethod 'http://127.0.0.1:3000/control/filtering/status' -Headers $h).filters.url
$lists=@(@{name='HaGeZi DoH/VPN/Proxy Bypass';url='https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/doh-vpn-proxy-bypass.txt'},@{name='Perflyst SmartTV';url='https://raw.githubusercontent.com/Perflyst/PiHoleBlocklist/master/SmartTV.txt'})
foreach($l in $lists){ if($have -contains $l.url){'already: '+$l.name} else { try{ Invoke-RestMethod 'http://127.0.0.1:3000/control/filtering/add_url' -Method Post -Headers $h -ContentType 'application/json' -Body (@{name=$l.name;url=$l.url;whitelist=$false}|ConvertTo-Json) | Out-Null; 'added: '+$l.name }catch{'fail '+$l.name+': '+$_} } }
foreach($d in 'dns.google','logs.roku.com'){ $r=Invoke-RestMethod ('http://127.0.0.1:3000/control/filtering/check_host?name='+$d) -Headers $h; $d+' -> '+$r.reason }
