$t=Get-Content 'C:\Users\YOU\Tools\AdGuardHome\ADMIN-LOGIN.txt'
$u=($t|sls -Pattern '(?i)user\w*\s*[:=]\s*(\S+)').Matches[0].Groups[1].Value
$p=($t|sls -Pattern '(?i)pass\w*\s*[:=]\s*(\S+)').Matches[0].Groups[1].Value
$h=@{Authorization='Basic '+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($u+':'+$p))}
$c=Invoke-RestMethod 'http://127.0.0.1:3000/control/filtering/check_host?name=gmss.use2.prd.api.discomax.com' -Headers $h
'gmss blocked by: '+(($c.rules|%{$_.text+' (list '+$_.filter_list_id+')'}) -join '; ')
$s=Invoke-RestMethod 'http://127.0.0.1:3000/control/filtering/status' -Headers $h
$rules=@($s.user_rules)
foreach($a in '@@||gmss.use2.prd.api.discomax.com^','@@||amer-free.prd.media.max.com^','@@||emea-free.prd.media.max.com^','@@||oceania-free.prd.media.max.com^'){ if($rules -notcontains $a){$rules+=$a} }
Invoke-RestMethod 'http://127.0.0.1:3000/control/filtering/set_rules' -Method Post -Headers $h -ContentType 'application/json' -Body (@{rules=$rules}|ConvertTo-Json) | Out-Null
foreach($d in 'gmss.use2.prd.api.discomax.com','cf.amer-free.prd.media.max.com'){ $r=Invoke-RestMethod ('http://127.0.0.1:3000/control/filtering/check_host?name='+$d) -Headers $h; $d+' -> '+$r.reason }
