$t=Get-Content 'C:\Users\YOU\Tools\AdGuardHome\ADMIN-LOGIN.txt'
$u=($t|sls -Pattern '(?i)user\w*\s*[:=]\s*(\S+)').Matches[0].Groups[1].Value
$p=($t|sls -Pattern '(?i)pass\w*\s*[:=]\s*(\S+)').Matches[0].Groups[1].Value
$h=@{Authorization='Basic '+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($u+':'+$p))}
$s=Invoke-RestMethod 'http://127.0.0.1:3000/control/filtering/status' -Headers $h
'list 1792704379: '+(@($s.filters)+@($s.whitelist_filters) | ? id -eq 1792704379 | % {$_.name+' '+$_.url})
$rules=@($s.user_rules)
if($rules -notcontains '||ravm.tv^$important'){ $rules+='||ravm.tv^$important' }
Invoke-RestMethod 'http://127.0.0.1:3000/control/filtering/set_rules' -Method Post -Headers $h -ContentType 'application/json' -Body (@{rules=$rules}|ConvertTo-Json) | Out-Null
foreach($d in 'display.ravm.tv','p.ravm.tv'){ $r=Invoke-RestMethod ('http://127.0.0.1:3000/control/filtering/check_host?name='+$d) -Headers $h; $d+' -> '+$r.reason }
