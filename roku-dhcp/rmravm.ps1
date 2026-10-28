$t=Get-Content 'C:\Users\YOU\Tools\AdGuardHome\ADMIN-LOGIN.txt'
$u=($t|sls -Pattern '(?i)user\w*\s*[:=]\s*(\S+)').Matches[0].Groups[1].Value
$p=($t|sls -Pattern '(?i)pass\w*\s*[:=]\s*(\S+)').Matches[0].Groups[1].Value
$h=@{Authorization='Basic '+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($u+':'+$p))}
$s=Invoke-RestMethod 'http://127.0.0.1:3000/control/filtering/status' -Headers $h
$rules=@($s.user_rules)
$rules | ? {$_ -match 'ravm'} | Set-Content 'C:\Users\YOU\Tools\roku-dhcp\removed-ravm-rule.txt'
$new=@($rules | ? {$_ -notmatch '^@@\|\|ravm\.tv\^'})
Invoke-RestMethod 'http://127.0.0.1:3000/control/filtering/set_rules' -Method Post -Headers $h -ContentType 'application/json' -Body (@{rules=$new}|ConvertTo-Json) | Out-Null
'removed: '+($rules.Count-$new.Count)
foreach($d in 'display.ravm.tv','p.ravm.tv'){ $r=Invoke-RestMethod ('http://127.0.0.1:3000/control/filtering/check_host?name='+$d) -Headers $h; $d+' -> '+$r.reason }
