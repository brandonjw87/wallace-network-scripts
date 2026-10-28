param([string[]]$Remove)
$t=Get-Content 'C:\Users\YOU\Tools\AdGuardHome\ADMIN-LOGIN.txt'
$u=($t|sls -Pattern '(?i)user\w*\s*[:=]\s*(\S+)').Matches[0].Groups[1].Value
$p=($t|sls -Pattern '(?i)pass\w*\s*[:=]\s*(\S+)').Matches[0].Groups[1].Value
$h=@{Authorization='Basic '+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($u+':'+$p))}
$s=Invoke-RestMethod 'http://127.0.0.1:3000/control/filtering/status' -Headers $h
$Remove=@($Remove -split ",")
$rules=@($s.user_rules)
$new=@($rules | ? { $r=$_; -not ($Remove | ? { $r -like "*$_*" }) })
Invoke-RestMethod 'http://127.0.0.1:3000/control/filtering/set_rules' -Method Post -Headers $h -ContentType 'application/json' -Body (@{rules=$new}|ConvertTo-Json) | Out-Null
'removed '+($rules.Count-$new.Count)+'; now '+$new.Count
foreach($d in 'gmss.use2.prd.api.discomax.com','cf.amer-free.prd.media.max.com'){ $r=Invoke-RestMethod ('http://127.0.0.1:3000/control/filtering/check_host?name='+$d) -Headers $h; $d+' -> '+$r.reason }
