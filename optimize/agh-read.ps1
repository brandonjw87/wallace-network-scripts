$b=Get-ChildItem C:\Users\YOU\Tools\dev-config-backup -Directory -Filter 'net-*' | Sort Name | Select -Last 1
$src=Get-ChildItem C:\Users\YOU\Tools\AdGuardHome -Recurse -Filter AdGuardHome.yaml -EA 0 | Select -First 1
Copy-Item $src.FullName "$($b.FullName)\AdGuardHome.yaml.bak"
"PATH=$($src.FullName)" | Out-File "$($b.FullName)\agh-view.txt"
Get-Content $src.FullName | % { if($_ -match 'password|secret|token|key:'){ ($_ -replace ':.*',': <hidden>') } else { $_ } } | Out-File "$($b.FullName)\agh-view.txt" -Append
$acl=Get-Acl "$($b.FullName)\agh-view.txt"; icacls "$($b.FullName)\agh-view.txt" /grant Brandon:R | Out-Null
