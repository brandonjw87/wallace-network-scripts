# Shared AdGuard API helper (reads creds locally, never prints them)
function Get-AghHeaders {
  $t=Get-Content 'C:\Users\YOU\Tools\AdGuardHome\ADMIN-LOGIN.txt'
  $u=($t|Select-String -Pattern '(?i)user\w*\s*[:=]\s*(\S+)').Matches[0].Groups[1].Value
  $p=($t|Select-String -Pattern '(?i)pass\w*\s*[:=]\s*(\S+)').Matches[0].Groups[1].Value
  @{Authorization='Basic '+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($u+':'+$p))}
}
$AghBase='http://127.0.0.1:3000/control'
