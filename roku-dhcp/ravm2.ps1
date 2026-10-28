$t=Get-Content 'C:\Users\YOU\Tools\AdGuardHome\ADMIN-LOGIN.txt'
$u=($t|sls -Pattern '(?i)user\w*\s*[:=]\s*(\S+)').Matches[0].Groups[1].Value
$p=($t|sls -Pattern '(?i)pass\w*\s*[:=]\s*(\S+)').Matches[0].Groups[1].Value
$h=@{Authorization='Basic '+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($u+':'+$p))}
$r=Invoke-RestMethod 'http://127.0.0.1:3000/control/filtering/check_host?name=display.ravm.tv' -Headers $h
$r.rules | ft -AutoSize
$s=Invoke-RestMethod 'http://127.0.0.1:3000/control/filtering/status' -Headers $h
'user rules with ravm/roku:'; $s.user_rules | ? {$_ -match 'ravm|roku'}
'allowlists:'; $s.whitelist_filters | select id,name,enabled | ft
