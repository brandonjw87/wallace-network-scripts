$t=Get-Content 'C:\Users\YOU\Tools\AdGuardHome\ADMIN-LOGIN.txt'
$u=($t|sls -Pattern '(?i)user\w*\s*[:=]\s*(\S+)').Matches[0].Groups[1].Value
$p=($t|sls -Pattern '(?i)pass\w*\s*[:=]\s*(\S+)').Matches[0].Groups[1].Value
$h=@{Authorization='Basic '+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($u+':'+$p))}
$r=Invoke-RestMethod 'http://127.0.0.1:3000/control/querylog?limit=500&search=roku' -Headers $h
'roku queries: '+@($r.data).Count+'  blocked: '+@($r.data|? {$_.reason -like 'Filtered*'}).Count
$r.data | select -First 20 time,client,@{n='d';e={$_.question.name}},reason | ft -AutoSize
