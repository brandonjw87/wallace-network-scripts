# Wallace-Roku status: hotspot state, clients, AdGuard per-hour totals. No admin needed.
param([int]$Hours=6)
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null=[Windows.Networking.Connectivity.NetworkInformation,Windows.Networking.Connectivity,ContentType=WindowsRuntime]
$null=[Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager,Windows.Networking.NetworkOperators,ContentType=WindowsRuntime]
try { $m=[Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile([Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile())
  $c=$m.GetCurrentAccessPointConfiguration(); "Hotspot: $($m.TetheringOperationalState)  SSID $($c.Ssid)  band $($c.Band)  clients $($m.ClientCount)/$($m.MaxClientCount)"
  foreach($x in $m.GetTetheringClients()){ $hn=@($x.HostNames|%{$_.DisplayName}); "  {0}  {1}" -f $x.MacAddress,($hn -join '  ') } } catch { "Hotspot query failed: $_" }
$w=netsh wlan show interfaces | Select-String 'SSID|Channel|Signal|Receive rate' | ? { $_ -notmatch 'BSSID' }; "Uplink:"; $w | % { "  "+$_.Line.Trim() }
"Services: " + ((Get-Service icssvc,SharedAccess,AdGuardHome -EA SilentlyContinue | % { "$($_.Name)=$($_.Status)" }) -join '  ')
. "$PSScriptRoot\agh-common.ps1"; $h=Get-AghHeaders
$cut=(Get-Date).AddHours(-$Hours); $all=@(); $older=$null
for($i=0;$i -lt 40;$i++){ $u="$AghBase/querylog?limit=500"+$(if($older){"&older_than="+[uri]::EscapeDataString($older)}); $r=Invoke-RestMethod $u -Headers $h; if(-not $r.data){break}; $all+=$r.data; $older=$r.oldest; if([datetime]$r.oldest -lt $cut){break} }
$q=@($all|?{[datetime]$_.time -ge $cut})
"AdGuard last ${Hours}h (note: hotspot clients appear as 127.0.0.1 via ICS proxy):"
"  Hour              Total  Blocked   %"
$q | group { ([datetime]$_.time).ToString('MM-dd HH:00') } | sort Name | % { $b=@($_.Group|? reason -like 'Filtered*').Count; "  {0}  {1,6}  {2,7}  {3,4:N1}" -f $_.Name,$_.Count,$b,(100*$b/$_.Count) }
"Top blocked:"; $q|? reason -like 'Filtered*' | group {$_.question.name} | sort Count -desc | select -first 10 | % { "  $($_.Count) $($_.Name)" }
"Top TV-related allowed:"; $q|? { $_.reason -notlike 'Filtered*' -and $_.question.name -match 'roku|ravm|amazon|aiv|primevideo|hulu|netflix' } | group {$_.question.name} | sort Count -desc | select -first 10 | % { "  $($_.Count) $($_.Name)" }
