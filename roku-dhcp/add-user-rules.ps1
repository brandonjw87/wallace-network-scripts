param([string[]]$Rules=@())
. "$PSScriptRoot\agh-common.ps1"; $h=Get-AghHeaders
$f=Invoke-RestMethod "$AghBase/filtering/status" -Headers $h
$bk=Join-Path $PSScriptRoot ("user-rules-backup-{0}.txt" -f (Get-Date -f 'yyyyMMdd-HHmm')); $f.user_rules | Set-Content $bk; "backup $bk ($(@($f.user_rules).Count) rules)"
$new=$Rules
$rules=@($f.user_rules); $add=$new | ? { $rules -notcontains $_ }
if($add){ $body=@{rules=@($rules+$add)}|ConvertTo-Json; Invoke-RestMethod "$AghBase/filtering/set_rules" -Method Post -Headers $h -ContentType 'application/json' -Body $body | Out-Null; "added: $($add -join ', ')" } else { 'nothing to add' }
foreach($d in 'cf.amer-free.prd.media.max.com','gcp.emea-free.prd.media.max.com','gmss.use2.prd.api.discomax.com','register.mediamelon.com','gcp.prd.media.h264.io','default.any-amer.prd.api.discomax.com','images.cdn.prd.api.discomax.com','busy.any-amer.prd.api.discomax.com'){ $r=Invoke-RestMethod "$AghBase/filtering/check_host?name=$d" -Headers $h; "{0,-34} {1}" -f $d,$r.reason }
"now $(@((Invoke-RestMethod "$AghBase/filtering/status" -Headers $h).user_rules).Count) user rules"
