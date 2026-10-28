. "$PSScriptRoot\agh-common.ps1"; $h=Get-AghHeaders
$want=@('||amer-free.prd.media.max.com^$important','||emea-free.prd.media.max.com^$important','||oceania-free.prd.media.max.com^$important','||gmss.use2.prd.api.discomax.com^$important','||register.mediamelon.com^','||litix.io^')
$r=@((Invoke-RestMethod "$AghBase/filtering/status" -Headers $h).user_rules) | ? { $_ -notmatch ',\|\|' }
$r=@($r)+@($want | ? { $r -notcontains $_ })
Invoke-RestMethod "$AghBase/filtering/set_rules" -Method Post -Headers $h -ContentType 'application/json' -Body (@{rules=$r}|ConvertTo-Json) | Out-Null
Start-Sleep 2
"user rules now $(@((Invoke-RestMethod "$AghBase/filtering/status" -Headers $h).user_rules).Count)"
foreach($d in 'cf.amer-free.prd.media.max.com','gcp.emea-free.prd.media.max.com','cf.oceania-free.prd.media.max.com','gmss.use2.prd.api.discomax.com','register.mediamelon.com','out053a.litix.io','gcp.prd.media.h264.io','default.any-amer.prd.api.discomax.com','images.cdn.prd.api.discomax.com','busy.any-amer.prd.api.discomax.com','default.beam-amer.prd.api.discomax.com'){ $x=Invoke-RestMethod "$AghBase/filtering/check_host?name=$d" -Headers $h; "{0,-42} {1}" -f $d,$x.reason }
