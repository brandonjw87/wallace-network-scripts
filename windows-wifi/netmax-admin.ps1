$ErrorActionPreference='Continue'
$B='C:\Users\YOU\Tools\dev-config-backup\pre-netmax-20261026-165553'; $Log='C:\Users\YOU\Tools\netmax-admin-log.txt'
function L($m){ "$(Get-Date -f 'HH:mm:ss') $m" | Out-File $Log -Append -Encoding utf8 }
"=== netmax-admin start $(Get-Date)" | Out-File $Log -Encoding utf8
$id=[Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
L "admin=$($id.IsInRole('Administrators'))"
# ---- 1+2 AdGuard yaml
try {
 $dir='C:\Users\YOU\Tools\AdGuardHome'; $y="$dir\AdGuardHome.yaml"
 Copy-Item $y "$B\AdGuardHome.yaml" -Force; L "backed up yaml -> $B\AdGuardHome.yaml"
 Stop-Service AdGuardHome -Force; L 'AdGuard stopped'
 $lines=[Collections.Generic.List[string]](Get-Content $y)
 function SetList($key,$indent,$vals){
  $i=-1; for($k=0;$k -lt $lines.Count;$k++){ if($lines[$k] -match "^$indent${key}:"){ $i=$k; break } }
  if($i -lt 0){ L "WARN key $key not found"; return }
  $j=$i+1; while($j -lt $lines.Count -and $lines[$j] -match "^$indent\s*- "){ $j++ }
  $lines.RemoveRange($i,$j-$i)
  $new=@("$indent${key}:")+($vals|%{"$indent  - $_"}); $lines.InsertRange($i,[string[]]$new); L "set $key"
 }
 function SetScalar($key,$val){
  $hit=$false; for($k=0;$k -lt $lines.Count;$k++){ if($lines[$k] -match "^(  )${key}:"){ $lines[$k]="  ${key}: $val"; $hit=$true; break } }
  L "scalar $key=$val found=$hit"; return $hit
 }
 SetList 'upstream_dns' '  ' @('https://dns.quad9.net/dns-query','https://cloudflare-dns.com/dns-query','https://dns.google/dns-query')
 SetList 'bootstrap_dns' '  ' @('9.9.9.9','1.1.1.1')
 if(-not (SetScalar 'upstream_mode' 'parallel')){ $null=SetScalar 'parallel_requests' 'true' }
 $null=SetScalar 'cache_size' '16777216'; $null=SetScalar 'cache_optimistic' 'true'; $null=SetScalar 'enable_dnssec' 'true'
 # filters
 $fi=-1; for($k=0;$k -lt $lines.Count;$k++){ if($lines[$k] -match '^filters:'){ $fi=$k; break } }
 $want=[ordered]@{'HaGeZi native.roku'='https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/native.roku.txt';'HaGeZi native.lgwebos'='https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/native.lgwebos.txt';'HaGeZi Pro'='https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/pro.txt';'HaGeZi TIF medium'='https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/tif.medium.txt'}
 $txt=$lines -join "`n"; $ids=[regex]::Matches($txt,'(?m)^\s+id: (\d+)')|%{[long]$_.Groups[1].Value}; $nid=([long](($ids|measure -Max).Maximum))+1; if($nid -lt 1000){$nid=1000}
 $add=@(); foreach($n in $want.Keys){ $u=$want[$n]; $base=($u -split '/')[-1]; if($txt -match [regex]::Escape($base)){ L "filter dup skip $n" } else { $add+=@('  - enabled: true',"    url: $u","    name: $n","    id: $nid"); $nid++; L "filter add $n" } }
 if($add){ if($lines[$fi] -match '^filters:\s*\[\]'){ $lines[$fi]='filters:'; $lines.InsertRange($fi+1,[string[]]$add) } else { $j=$fi+1; while($j -lt $lines.Count -and $lines[$j] -match '^\s'){ $j++ }; $lines.InsertRange($j,[string[]]$add) } }
 # user rules
 $ui=-1; for($k=0;$k -lt $lines.Count;$k++){ if($lines[$k] -match '^user_rules:'){ $ui=$k; break } }
 $rules='@@||googlevideo.com^','@@||youtubei.googleapis.com^','@@||s.youtube.com^','@@||api.roku.com^','@@||image.roku.com^','@@||channels.roku.com^','@@||cigars.roku.com^','@@||sponsor.ajay.app^','@@||youtube.com^','@@||ytimg.com^'
 $ra=@(); foreach($r in $rules){ if(-not ($lines | ?{ $_ -like "*$r*" })){ $ra+="  - '$r'" } }
 if($ui -lt 0){ $lines.Add('user_rules:'); $lines.AddRange([string[]]$ra) } elseif($ra){ if($lines[$ui] -match '\[\]'){ $lines[$ui]='user_rules:'; $lines.InsertRange($ui+1,[string[]]$ra) } else { $j=$ui+1; while($j -lt $lines.Count -and $lines[$j] -match '^\s+- '){ $j++ }; $lines.InsertRange($j,[string[]]$ra) } }
 L "user rules added: $($ra.Count)"
 [IO.File]::WriteAllLines($y,[string[]]$lines,(New-Object Text.UTF8Encoding $false))
 $chk=& "$dir\AdGuardHome.exe" --check-config -c $y -w $dir 2>&1; L "check-config exit=$LASTEXITCODE $(($chk|select -Last 2) -join ' | ')"
 if($LASTEXITCODE -ne 0){ Copy-Item "$B\AdGuardHome.yaml" $y -Force; L 'ROLLBACK yaml restored' }
 Start-Service AdGuardHome; Start-Sleep 5; L "AdGuard $((Get-Service AdGuardHome).Status)"
 if((Get-Service AdGuardHome).Status -ne 'Running'){ Copy-Item "$B\AdGuardHome.yaml" $y -Force; Start-Service AdGuardHome; L 'ROLLBACK yaml (service failed)' }
} catch { L "ERROR adguard $_"; Start-Service AdGuardHome -EA 0 }
# ---- ICS
try { $k='HKLM:\SYSTEM\CurrentControlSet\Services\icssvc\Settings'; reg export 'HKLM\SYSTEM\CurrentControlSet\Services\icssvc\Settings' "$B\icssvc-settings.reg" /y | Out-Null
 if(-not (Test-Path $k)){ New-Item $k -Force|Out-Null }; New-ItemProperty $k PeerlessTimeout -Value 0 -PropertyType DWord -Force|Out-Null; L 'PeerlessTimeout=0'
 Restart-Service icssvc -Force -EA 0; L "icssvc $((Get-Service icssvc).Status)" } catch { L "ERROR ics $_" }
# ---- adapters
foreach($a in 'Ethernet','Wi-Fi'){ try {
 Get-NetAdapterAdvancedProperty -Name $a | select Name,DisplayName,RegistryKeyword,RegistryValue | Export-Csv "$B\adv-$a.csv" -NoType
 Get-NetAdapterPowerManagement -Name $a | Out-String | Out-File "$B\pm-$a.txt"
 Disable-NetAdapterPowerManagement -Name $a -NoRestart -EA Stop; L "$a power mgmt disabled"
 $pnp=(Get-NetAdapter -Name $a).PnPDeviceID; $ck=(Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}' -EA 0 | ?{ (Get-ItemProperty $_.PSPath -EA 0).DeviceInstanceID -eq $pnp }).PSPath
 if($ck){ "$a PnPCapabilities=$((Get-ItemProperty $ck).PnPCapabilities) at $ck" | Out-File "$B\pnp.txt" -Append; Set-ItemProperty $ck PnPCapabilities 24 -Type DWord; L "$a PnPCapabilities=24" }
 Get-NetAdapterAdvancedProperty -Name $a | ?{ $_.DisplayName -match 'Energy|Green|EEE|Power Sav' -or $_.RegistryKeyword -match 'EEE|Green' } | %{ $dv=($_.ValidDisplayValues | ?{ $_ -match 'Disable|Off' } | select -First 1); if($dv){ Set-NetAdapterAdvancedProperty -Name $a -DisplayName $_.DisplayName -DisplayValue $dv -NoRestart; L "$a '$($_.DisplayName)'=$dv" } }
} catch { L "WARN adapter $a $_" } }
# ---- power plan
try { powercfg /export "$B\powerplan-active.pow" scheme_current | Out-Null
 $hp='8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'; powercfg /setactive $hp; L "active plan: $(powercfg /getactivescheme)"
 powercfg /setacvalueindex scheme_current 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0
 powercfg /setacvalueindex scheme_current 501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d277-404b-b6da-e5fa1a576df5 0
 powercfg /setactive scheme_current; L 'USB selective suspend off, PCIe ASPM off (AC)' } catch { L "ERROR power $_" }
L "tcp autotuning: $((netsh int tcp show global | Select-String 'Auto-Tuning').Line.Trim())"
if(-not ((netsh int tcp show global|Out-String) -match 'Auto-Tuning Level\s*:\s*normal')){ netsh int tcp set global autotuninglevel=normal | Out-Null; L 'autotuning set normal' }
# ---- firewall
try { Get-NetFirewallRule -DisplayName 'WR2 Block HardcodedDNS*' -EA 0 | Remove-NetFirewallRule
 foreach($p in 'TCP','UDP'){ New-NetFirewallRule -DisplayName "WR2 Block HardcodedDNS $p" -Group 'WR2 Block HardcodedDNS' -Direction Inbound -Action Block -Protocol $p -RemoteAddress 192.0.2.19/24 -LocalAddress 8.8.8.8,8.8.4.4,1.1.1.1,1.0.0.1 -LocalPort 53,853 | Out-Null }
 L 'firewall rules added (remove: Remove-NetFirewallRule -Group "WR2 Block HardcodedDNS")' } catch { L "ERROR fw $_" }
L "OpenDHCP: $((Select-String -Path C:\OpenDHCPServer\OpenDHCPServer.ini -Pattern '^\s*(DomainServer|Router)=').Line -join '; ')"
L 'DONE'