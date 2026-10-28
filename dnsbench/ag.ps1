$t=[IO.File]::ReadAllText('C:\Users\YOU\Tools\AdGuardHome\ADMIN-LOGIN.txt'); $u=[regex]::Match($t,'(?i)user\w*\s*[:=]\s*(\S+)').Groups[1].Value; $p=[regex]::Match($t,'(?i)pass\w*\s*[:=]\s*(\S+)').Groups[1].Value
$global:H=@{Authorization='Basic '+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${u}:$p"))}; Remove-Variable t,p
function global:AG($path){Invoke-RestMethod -Headers $H "http://127.0.0.1:3000/control/$path"}
function global:AGP($path,$body){Invoke-RestMethod -Method Post -ContentType 'application/json' -Headers $H "http://127.0.0.1:3000/control/$path" -Body ($body|ConvertTo-Json -Depth 6)}
