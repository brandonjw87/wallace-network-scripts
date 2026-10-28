Get-NetNeighbor -IPAddress 192.168.137.* | ? State -in 'Reachable','Stale','Delay','Probe' | ft IPAddress,LinkLayerAddress,State
$t=Get-Content 'C:\Users\YOU\Tools\AdGuardHome\ADMIN-LOGIN.txt'
$u=($t|sls -Pattern '(?i)user\w*\s*[:=]\s*(\S+)').Matches[0].Groups[1].Value
$p=($t|sls -Pattern '(?i)pass\w*\s*[:=]\s*(\S+)').Matches[0].Groups[1].Value
$h=@{Authorization='Basic '+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($u+':'+$p))}
$r=Invoke-RestMethod 'http://127.0.0.1:3000/control/querylog?limit=500' -Headers $h
$q=@($r.data | ? client -like '192.168.137.*')
'hotspot queries: '+$q.Count
'blocked: '+@($q|? {$_.reason -like 'Filtered*'}).Count
$q | select -First 30 @{n='c';e={$_.client}},@{n='d';e={$_.question.name}},reason | ft -AutoSize
