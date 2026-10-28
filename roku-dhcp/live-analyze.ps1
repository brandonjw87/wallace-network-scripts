$d=Get-Content "$PSScriptRoot\live-monitor.json" -Raw | ConvertFrom-Json
. "$PSScriptRoot\agh-common.ps1"; $h=Get-AghHeaders
$names=@{}; ((Invoke-RestMethod "$AghBase/filtering/status" -Headers $h).filters) | % { $names["$($_.id)"]=$_.name }; $names['0']='user rules'
"total since cut: $($d.Count); blocked $(@($d|? reason -like 'Filtered*').Count)"
$pat='roku|ravm|ads?\b|ad\.|adserv|doubleclick|adsrvr|innovid|imasdk|spotx|freewheel|fwmrm|moat|amazon-adsystem|scorecard|conviva|track|metric|telemetry|analytic|pixel|beacon|logs?\.|events?\.|dns\.google|doh|cloudflare-dns|quad9|googlesyndication|2mdn|serving-sys|tremor|springserve|pubmatic|yieldmo|tapad|samba|innovid|iris\.tv|nielsen|imrworldwide'
$d | ? { $_.n -match $pat } | group n | sort Count -desc | % { $g=$_.Group[0]; $b=@($_.Group|? reason -like 'Filtered*').Count; $l=($g.fid -split ',' | ?{$_} | % { $names[$_] }) -join '/'; "{0,4} {1,-48} blk={2,-3} {3} {4} [{5}]" -f $_.Count,$_.Name,$b,$g.reason,$g.rule,$l }
"--- other non-PC domains (excluding obvious PC)"; $d | ? { $_.n -notmatch $pat -and $_.n -notmatch 'cursor|microsoft|windows|bing|msn|office|live\.com|google|gstatic|github|claude|anthropic|mcafee|xbox|gamepass|wpad|example\.com|steelseries|nvidia|skype|msedge|azure' } | group n | sort Count -desc | select -first 60 | % { "{0,4} {1} {2}" -f $_.Count,$_.Name,$_.Group[0].reason }
