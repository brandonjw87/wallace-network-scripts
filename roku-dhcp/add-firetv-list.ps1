param([switch]$Rollback)
. "$PSScriptRoot\agh-common.ps1"; $h=Get-AghHeaders
$url='https://raw.githubusercontent.com/Perflyst/PiHoleBlocklist/master/AmazonFireTV.txt'
$f=Invoke-RestMethod "$AghBase/filtering/status" -Headers $h
$have=$f.filters | ? url -eq $url
if($Rollback){ if($have){ Invoke-RestMethod "$AghBase/filtering/remove_url" -Method Post -Headers $h -ContentType 'application/json' -Body (@{url=$url;whitelist=$false}|ConvertTo-Json) | Out-Null; 'removed' } else { 'not present' }; return }
if($have){ "already present rules=$($have.rules_count)" } else {
  Invoke-RestMethod "$AghBase/filtering/add_url" -Method Post -Headers $h -ContentType 'application/json' -Body (@{name='Perflyst AmazonFireTV';url=$url;whitelist=$false}|ConvertTo-Json) | Out-Null
  Start-Sleep 3; $n=(Invoke-RestMethod "$AghBase/filtering/status" -Headers $h).filters | ? url -eq $url; "added rules=$($n.rules_count)" }
# sanity: Prime Video / Appstore / OTA domains must not be blocked
foreach($d in 'atv-ps.amazon.com','api.amazon.com','primevideo.com','aiv-cdn.net','softwareupdates.amazon.com','appstore-api.amazon.com','amazon.com','mads.amazon-adsystem.com','device-metrics-us.amazon.com','aviary.amazon.com'){
  $r=Invoke-RestMethod "$AghBase/filtering/check_host?name=$d" -Headers $h; "{0,-34} {1}" -f $d,$r.reason }
