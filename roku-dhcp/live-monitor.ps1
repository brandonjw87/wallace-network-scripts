param([int]$Minutes=6,[int]$Every=25,[string]$Since='09:31')
. "$PSScriptRoot\agh-common.ps1"; $h=Get-AghHeaders
$cut=[datetime]::Parse((Get-Date -f 'yyyy-MM-dd')+" $Since")
$out=Join-Path $PSScriptRoot 'live-monitor.json'
$seen=@{}; $end=(Get-Date).AddMinutes($Minutes)
do {
  $older=$null
  for($i=0;$i -lt 20;$i++){ $u="$AghBase/querylog?limit=500"+$(if($older){"&older_than="+[uri]::EscapeDataString($older)}); $r=Invoke-RestMethod $u -Headers $h; if(-not $r.data){break}
    foreach($q in $r.data){ if([datetime]$q.time -ge $cut){ $k="$($q.time)|$($q.question.name)|$($q.question.type)"; if(-not $seen.ContainsKey($k)){ $seen[$k]=[pscustomobject]@{t=$q.time;n=$q.question.name;ty=$q.question.type;reason=$q.reason;rule=(@($q.rules|%{$_.text}) -join ' ; ');fid=(@($q.rules|%{$_.filter_list_id}) -join ',');status=$q.status;ans=@($q.answer).Count} } } }
    $older=$r.oldest; if([datetime]$r.oldest -lt $cut){break} }
  "$(Get-Date -f T) collected $($seen.Count)"
  $seen.Values | ConvertTo-Json -Depth 3 | Set-Content $out
  if((Get-Date) -lt $end){ Start-Sleep $Every }
} while((Get-Date) -lt $end)
