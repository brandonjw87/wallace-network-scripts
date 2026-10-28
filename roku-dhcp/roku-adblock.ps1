<#
 roku-adblock.ps1  - Roku-only DHCP (Open DHCP Server 2.01) handing out DNS = AdGuard Home (192.0.2.28)
 Usage:  .\roku-adblock.ps1 [-Action Menu|Discover|Install|Status|Test|Rollback|Watchdog|RegisterWatchdog] [-WhatIf]
 Discover/Status/Test are read-only and need no admin. Install/Rollback/RegisterWatchdog need admin.
 Credentials are read from ..\AdGuardHome\ADMIN-LOGIN.txt at runtime and NEVER printed or logged.
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param([ValidateSet('Menu','Discover','Install','Status','Test','Rollback','Watchdog','RegisterWatchdog')][string]$Action='Menu')

$ErrorActionPreference = 'Stop'
foreach($m in 'NetTCPIP','NetSecurity','ScheduledTasks','DnsClient','CimCmdlets','Microsoft.PowerShell.Management'){ Import-Module $m -EA SilentlyContinue 3>$null }
$Root    = $PSScriptRoot
$If      = 'Wi-Fi'
$PcIP    = '192.0.2.28'; $Gw = '192.0.2.15'; $Mask = '255.255.255.0'
$Pool    = '192.0.2.29-192.0.2.30'
$LeaseS  = 3600     # 1h on purpose (see README): shorter lease = faster fallback to router if PC/AdGuard dies
$OdsSvc  = 'OpenDHCPServer'   # verified: serviceName[] in OpenDHCPServer.cpp v2.01
$AghSvc  = 'AdGuardHome'      # verified: Get-Service / sc query on this PC
$AghUrl  = 'http://127.0.0.1:3000'
$Cred    = Join-Path (Split-Path $Root) 'AdGuardHome\ADMIN-LOGIN.txt'
$MacFile = Join-Path $Root 'roku-macs.txt'
$OuiFile = Join-Path $Root 'roku-oui-ieee.txt'
$OemFile = Join-Path $Root 'tv-oem-oui-ieee.txt'   # Hisense/TCL/Gaoshengda (hint only; too broad for the MAC filter)
$Log     = Join-Path $Root 'roku-adblock.log'
$BakDir  = Join-Path $Root 'backups'
$Stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$BlockList = 'https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/native.roku.txt'
$ExtraRules = @('||scribe.logs.roku.com^','||ads.roku.com^','||logs.roku.com^','||austin.logs.roku.com^','||giga.logs.roku.com^','||amoeba.web.roku.com^','||customer-feedbacks.web.roku.com^','||identity.ads.roku.com^','||p.ads.roku.com^','||events.roku.com^')

function Log($m,[string]$lvl='INFO'){ $l="$(Get-Date -f s) [$lvl] $m"; Write-Host $l; Add-Content $Log $l -WhatIf:$false }
function IsAdmin { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
function NeedAdmin { if(-not (IsAdmin) -and -not $WhatIfPreference){ throw 'Run from an elevated PowerShell (Run as administrator), or add -WhatIf for a dry run.' } }
function Norm($m){ ($m -replace '[-:\.]','').ToUpper() }
function Colon($m){ $n=Norm $m; ($n -split '(..)' | ? {$_}) -join ':' }
function OdsDir { foreach($p in 'C:\OpenDHCPServer',"$env:ProgramFiles\OpenDHCPServer","${env:ProgramFiles(x86)}\OpenDHCPServer"){ if(Test-Path "$p\OpenDHCPServer.exe"){ return $p } }
  $s=Get-CimInstance Win32_Service -Filter "Name='$OdsSvc'" -EA SilentlyContinue; if($s){ return Split-Path ($s.PathName.Trim('"') -replace '\.exe.*','.exe') }; $null }

function AghHeaders {
  if(-not (Test-Path $Cred)){ return $null }
  $t = Get-Content $Cred -Raw
  $u = [regex]::Match($t,'(?im)^\s*(user(name)?|login)\s*[:=]\s*(\S+)').Groups[3].Value
  $p = [regex]::Match($t,'(?im)^\s*pass(word)?\s*[:=]\s*(.+?)\s*$').Groups[2].Value
  if(-not $u -or -not $p){ return $null }
  @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${u}:${p}")) }
}
function Agh($path,$method='GET',$body=$null){ $h=AghHeaders; if(-not $h){ throw 'AdGuard login not parsable from ADMIN-LOGIN.txt (expects "username: x" / "password: y" lines)' }
  $a=@{Uri="$AghUrl$path";Headers=$h;Method=$method;UseBasicParsing=$true;TimeoutSec=10}; if($body){ $a.Body=($body|ConvertTo-Json -Depth 5); $a.ContentType='application/json' }
  Invoke-RestMethod @a }

function Get-RokuOuis { if(Test-Path $OuiFile){ Get-Content $OuiFile | ? {$_} | % { Norm $_ } } else { @() } }

function Get-EcpInfo($ip){
  try { $x=[xml](Invoke-WebRequest "http://${ip}:8060/query/device-info" -UseBasicParsing -TimeoutSec 4).Content; $d=$x.'device-info'
        [pscustomobject]@{IP=$ip;Name=$d.'user-device-name';Model=("$($d.'friendly-model-name') $($d.'model-number')" -replace '[^\x20-\x7E]',' ');Vendor=$d.'vendor-name';Net=$d.'network-type';WifiMac=$d.'wifi-mac';EthMac=$d.'ethernet-mac'} } catch { $null } }

function Discover {
  Log 'Discover: read-only scan of 192.0.2.20/24 (ping + TCP 8060 + ECP /query/device-info)'
  $probe = 1..254 | % { $ip="192.168.1.$_"; $c=New-Object Net.Sockets.TcpClient; [void](New-Object Net.NetworkInformation.Ping).SendPingAsync($ip,300); @{ip=$ip;c=$c;t=$c.ConnectAsync($ip,8060)} }
  Start-Sleep 3
  $open = $probe | ? { $_.t.IsCompleted -and -not $_.t.IsFaulted -and $_.c.Connected } | % { $_.ip }; $probe | % { $_.c.Dispose() }
  $roku = Get-RokuOuis; $oem = if(Test-Path $OemFile){ Get-Content $OemFile | ? {$_} | % { Norm $_ } } else { @() }
  $nb = Get-NetNeighbor -AddressFamily IPv4 -InterfaceAlias $If -EA SilentlyContinue | ? { $_.IPAddress -like '192.168.1.*' -and $_.LinkLayerAddress -and $_.LinkLayerAddress -notmatch '^(FF-|01-00-5E|00-00-00)' }
  $cand = @{}; $open | % { $cand[$_]='port 8060 open' }
  foreach($n in $nb){ $o=(Norm $n.LinkLayerAddress).Substring(0,6)
    if($roku -contains $o){ $cand[$n.IPAddress]+=' Roku OUI' } elseif($oem -contains $o){ $cand[$n.IPAddress]+=' Hisense/TCL OUI' } }
  try { (Agh '/control/querylog?search=roku.com&limit=500').data | % { $_.client } | ? { $_ -like '192.168.1.*' -and $_ -ne $PcIP } | Sort -Unique | % { $cand[$_]+=' AdGuard roku.com' } } catch { Log "AdGuard query-log hint skipped: $($_.Exception.Message)" 'WARN' }
  $conf=@(); $unconf=@()
  foreach($ip in $cand.Keys){ if($ip -eq $PcIP){ continue }; $e=Get-EcpInfo $ip
    if($e){ $e | Add-Member Hint $cand[$ip].Trim(); $conf+=$e } else { $mac=($nb | ? IPAddress -eq $ip | select -First 1).LinkLayerAddress; $unconf+=[pscustomobject]@{IP=$ip;MAC=$(if($mac){Colon $mac});Hint=$cand[$ip].Trim()} } }
  $conf = $conf | Sort { [version]$_.IP }
  Write-Host "`nECP-CONFIRMED Rokus (authoritative):"; $conf | ft IP,Name,Model,Vendor,Net,WifiMac,EthMac -AutoSize | Out-String -Width 200 | Write-Host
  if($unconf){ Write-Host 'Candidates NOT confirmed by ECP (ignored; may be asleep, ECP disabled, or not a Roku):'; $unconf | ft -AutoSize | Out-String | Write-Host }
  if($PSCmdlet.ShouldProcess($MacFile,'write ECP-confirmed Roku list')){
    if(Test-Path $MacFile){ New-Item -ItemType Directory -Force $BakDir -WhatIf:$false | Out-Null; Copy-Item $MacFile "$BakDir\roku-macs.$Stamp.txt" -WhatIf:$false }
    $lines = @("# MAC,IP,Name,Model  - ECP-confirmed $Stamp. Add rows by hand for Rokus that were off (lines with # ignored).")
    foreach($r in $conf){ $act = if($r.Net -eq 'ethernet' -and $r.EthMac){ $r.EthMac } else { $r.WifiMac }
      if($act){ $lines += "$(Colon $act),$($r.IP),$($r.Name -replace ',',' '),$($r.Model -replace ',',' ')" }
      $other = if($act -eq $r.WifiMac){ $r.EthMac } else { $r.WifiMac }
      if($other){ $lines += "$(Colon $other),,$($r.Name -replace ',',' ') (other NIC),$($r.Model -replace ',',' ')" } }
    $lines | Set-Content $MacFile -WhatIf:$false; Log "Discover: wrote $(@($conf).Count) ECP-confirmed Roku(s) to $MacFile" }
  $conf
}

function Build-Ini {
  $sb = New-Object Text.StringBuilder
  [void]$sb.AppendLine("; Generated by roku-adblock.ps1 $Stamp - Open DHCP Server 2.01 (keys verified vs OpenDHCPServerManual.pdf)")
  [void]$sb.AppendLine("[LISTEN_ON]`r`n$PcIP`r`n`r`n[LOGGING]`r`nLogLevel=Normal`r`n`r`n[HTTP_INTERFACE]`r`nHTTPServer=127.0.0.1:6789`r`n")
  [void]$sb.AppendLine("[GLOBAL_OPTIONS]`r`nSubnetMask=$Mask`r`nRouter=$Gw`r`nDomainServer=$PcIP`r`nAddressTime=$LeaseS`r`n")
  # Range only for Roku OUIs (max 32 FilterMacRange per RANGE_SET). Non-matching clients get NO offer (checkRange() in source).
  [void]$sb.AppendLine("[RANGE_SET]`r`nDHCPRange=$Pool")
  foreach($o in (Get-RokuOuis | Select -First 32)){ $c=Colon $o; [void]$sb.AppendLine("FilterMacRange=${c}:00:00:00-${c}:FF:FF:FF") }
  [void]$sb.AppendLine('')
  # Known Rokus: pin to the SAME IP the Spectrum router already gave them -> no conflict whichever server wins.
  if(Test-Path $MacFile){ Get-Content $MacFile | ? { $_ -and $_ -notmatch '^\s*#' } | % { $f=$_ -split ','; if(-not $f[1].Trim()){ return }; [void]$sb.AppendLine("[$($f[0].ToLower())]`r`nIP=$($f[1].Trim())`r`n") } }
  $sb.ToString()
}

function Install {
  NeedAdmin; Log "Install start (WhatIf=$WhatIfPreference)"
  New-Item -ItemType Directory -Force $BakDir -WhatIf:$false | Out-Null
  if(-not (Test-Path $MacFile)){ Log 'No roku-macs.txt yet - running Discover first' ; Discover | Out-Null }
  # 1. Static IP (idempotent)
  $cur = Get-NetIPInterface -InterfaceAlias $If -AddressFamily IPv4
  if($cur.Dhcp -eq 'Enabled' -or -not (Get-NetIPAddress -InterfaceAlias $If -IPAddress $PcIP -EA SilentlyContinue)){
    if($PSCmdlet.ShouldProcess($If,"set static $PcIP/24 gw $Gw dns 127.0.0.1,$Gw (backup first)")){
      Get-NetIPConfiguration -InterfaceAlias $If -Detailed | Out-File "$BakDir\ipconfig.$Stamp.txt"
      Set-NetIPInterface -InterfaceAlias $If -Dhcp Disabled
      Get-NetIPAddress -InterfaceAlias $If -AddressFamily IPv4 -EA SilentlyContinue | Remove-NetIPAddress -Confirm:$false
      Remove-NetRoute -InterfaceAlias $If -DestinationPrefix 0.0.0.0/0 -Confirm:$false -EA SilentlyContinue
      New-NetIPAddress -InterfaceAlias $If -IPAddress $PcIP -PrefixLength 24 -DefaultGateway $Gw | Out-Null
      Set-DnsClientServerAddress -InterfaceAlias $If -ServerAddresses 127.0.0.1,$Gw; Log 'Static IP set' }
  } else { Log 'Static IP already in place - skip' }
  # 2. Firewall (idempotent)
  foreach($r in @(@('roku-dhcp UDP67','UDP',67),@('roku-dhcp DNS53 UDP','UDP',53),@('roku-dhcp DNS53 TCP','TCP',53))){
    if(-not (Get-NetFirewallRule -DisplayName $r[0] -EA SilentlyContinue)){ if($PSCmdlet.ShouldProcess($r[0],'add inbound firewall rule (Private)')){ New-NetFirewallRule -DisplayName $r[0] -Direction Inbound -Protocol $r[1] -LocalPort $r[2] -Action Allow -Profile Private | Out-Null } } else { Log "$($r[0]) exists - skip" } }
  # 3. Open DHCP Server binary
  $d = OdsDir
  if(-not $d){ $inst = Join-Path $Root 'OpenDHCPServerInstaller64bitV2.01.exe'
    $h=-join ([Security.Cryptography.SHA256]::Create().ComputeHash([IO.File]::ReadAllBytes($inst)) | % { $_.ToString('X2') })
    if($h -ne '0311903A337821DF13C85B73C32EDE3DCC3A4699EAA3DB058E0C5ADA10660064'){ throw "Installer SHA256 mismatch: $h" }
    if($PSCmdlet.ShouldProcess($inst,'run Open DHCP Server installer (interactive; accept default C:\OpenDHCPServer)')){ Start-Process $inst -Wait; $d=OdsDir; if(-not $d){ throw 'Open DHCP Server not found after install' } }
    else { $d='C:\OpenDHCPServer' } }
  # 4. Config (backup existing)
  $ini = Join-Path $d 'OpenDHCPServer.ini'; $new = Build-Ini
  Write-Host "`n----- OpenDHCPServer.ini that would be written to $ini -----`n$new"
  if($PSCmdlet.ShouldProcess($ini,'backup + write config')){ if(Test-Path $ini){ Copy-Item $ini "$BakDir\OpenDHCPServer.ini.$Stamp" }; Set-Content $ini $new -Encoding ASCII; Log "Wrote $ini" }
  # 5. Optional AdGuard Roku blocklist + rules (appends; never removes existing rules)
  AdGuardRules
  # 6. Service
  if($PSCmdlet.ShouldProcess($OdsSvc,'set Automatic + (re)start service')){
    if(-not (Get-Service $OdsSvc -EA SilentlyContinue)){ & (Join-Path $d 'OpenDHCPServer.exe') -i }
    Set-Service $OdsSvc -StartupType Automatic; Restart-Service $OdsSvc; Log 'OpenDHCPServer started' }
  RegisterWatchdog
  Log 'Install done. Now power-cycle each Roku, then run: .\roku-adblock.ps1 -Action Test'
}

function AdGuardRules {
  try { $st = Agh '/control/filtering/status' } catch { Log "AdGuard API unavailable, skipping blocklist: $($_.Exception.Message)" 'WARN'; return }
  if(-not ($st.filters | ? url -eq $BlockList)){ if($PSCmdlet.ShouldProcess('AdGuard','add filter list HaGeZi native.roku')){ Agh '/control/filtering/add_url' 'POST' @{name='HaGeZi Native Tracker - Roku';url=$BlockList;whitelist=$false} | Out-Null; Log 'Added HaGeZi native.roku' } } else { Log 'HaGeZi native.roku already present' }
  $have=@($st.user_rules); $add=$ExtraRules | ? { $have -notcontains $_ }
  if($add){ if($PSCmdlet.ShouldProcess('AdGuard','append user rules: '+($add -join ' '))){ Set-Content "$BakDir\adguard-user_rules.$Stamp.txt" $have; Agh '/control/filtering/set_rules' 'POST' @{rules=@($have+$add)} | Out-Null; Log "Appended $(@($add).Count) rules" } } else { Log 'Extra rules already present' }
}

function Status {
  foreach($s in $AghSvc,$OdsSvc){ $x=Get-Service $s -EA SilentlyContinue; Write-Host ("{0,-16} {1}" -f $s, $(if($x){"$($x.Status) / $($x.StartType)"}else{'not installed'})) }
  $ipi=Get-NetIPInterface -InterfaceAlias $If -AddressFamily IPv4; Write-Host "Wi-Fi DHCP client: $($ipi.Dhcp)   IPv4: $((Get-NetIPAddress -InterfaceAlias $If -AddressFamily IPv4).IPAddress -join ',')"
  try{ Resolve-DnsName example.com -Server $PcIP -DnsOnly -QuickTimeout | Out-Null; Write-Host "AdGuard DNS on ${PcIP}:53  OK" }catch{ Write-Host "AdGuard DNS on ${PcIP}:53  FAIL" }
  Write-Host "Firewall rules: $((Get-NetFirewallRule -DisplayName 'roku-dhcp*' -EA SilentlyContinue).DisplayName -join ', ')"
  $t=Get-ScheduledTask -TaskName roku-dhcp-watchdog -EA SilentlyContinue; Write-Host "Watchdog task: $(if($t){$t.State}else{'not registered'})"
  if(Test-Path $MacFile){ Write-Host "`nroku-macs.txt:"; Get-Content $MacFile | Write-Host }
}

function Test {
  if(-not (Test-Path $MacFile)){ throw 'Run Discover first' }
  $since=(Get-Date).AddMinutes(-30)
  try { $q=(Agh '/control/querylog?limit=1000').data } catch { throw "AdGuard API: $($_.Exception.Message)" }
  Get-Content $MacFile | ? { $_ -and $_ -notmatch '^\s*#' } | % { $f=$_ -split ','; $ip=$f[1].Trim(); if(-not $ip){ return }
    $hits=@($q | ? { $_.client -eq $ip -and [datetime]$_.time -gt $since })
    $blk=@($hits | ? { $_.reason -like 'Filtered*' })
    $v= if($hits){'USING ADGUARD'}else{'NOT SEEN in last 30 min (still on router DNS, idle, or using 8.8.8.8/IPv6)'}
    Write-Host ("{0,-17} {1,-15} queries={2,-4} blocked={3,-4} {4}" -f $f[0],$ip,$hits.Count,$blk.Count,$v) }
}

function Rollback {
  NeedAdmin; Log "Rollback start (WhatIf=$WhatIfPreference)"
  if(Get-Service $OdsSvc -EA SilentlyContinue){ if($PSCmdlet.ShouldProcess($OdsSvc,'stop + set Disabled (binary/config kept)')){ Stop-Service $OdsSvc -Force; Set-Service $OdsSvc -StartupType Disabled } }
  if($PSCmdlet.ShouldProcess('roku-dhcp-watchdog','unregister task')){ Unregister-ScheduledTask -TaskName roku-dhcp-watchdog -Confirm:$false -EA SilentlyContinue }
  if($PSCmdlet.ShouldProcess('roku-dhcp* firewall rules','remove')){ Get-NetFirewallRule -DisplayName 'roku-dhcp*' -EA SilentlyContinue | Remove-NetFirewallRule }
  if($PSCmdlet.ShouldProcess($If,'back to DHCP + automatic DNS')){ Remove-NetRoute -InterfaceAlias $If -DestinationPrefix 0.0.0.0/0 -Confirm:$false -EA SilentlyContinue; Set-NetIPInterface -InterfaceAlias $If -Dhcp Enabled; Set-DnsClientServerAddress -InterfaceAlias $If -ResetServerAddresses; ipconfig /renew $If | Out-Null }
  Log 'Rollback done (AdGuard filter/rules left in place - harmless; remove in AdGuard UI if wanted). Power-cycle Rokus to re-lease from the router.'
}

function Watchdog {  # run by scheduled task every minute as SYSTEM
  $cnt = Join-Path $Root 'watchdog.failcount'; $ok=$true; $why=@()
  try{ Resolve-DnsName example.com -Server $PcIP -DnsOnly -QuickTimeout -EA Stop | Out-Null }catch{ $ok=$false; $why+='DNS no answer' }
  if((Get-Service $AghSvc).Status -ne 'Running'){ $ok=$false; $why+='AdGuardHome stopped'; Start-Service $AghSvc -EA SilentlyContinue }
  if($ok){ Set-Content $cnt 0; return }
  $n=[int](Get-Content $cnt -EA SilentlyContinue)+1; Set-Content $cnt $n; Log "Watchdog FAIL $n/3: $($why -join '; ')" 'WARN'
  if($n -ge 3 -and (Get-Service $OdsSvc -EA SilentlyContinue).Status -eq 'Running'){
    Stop-Service $OdsSvc -Force; Log 'Watchdog AUTO-ROLLBACK: OpenDHCPServer stopped so Rokus fall back to Spectrum router at next renewal (<= lease time).' 'ERROR'
    msg * "roku-adblock: AdGuard DNS down 3 checks in a row - Roku DHCP stopped (auto-rollback). Check AdGuard, then Start-Service $OdsSvc." 2>$null }
}

function RegisterWatchdog {
  NeedAdmin
  if($PSCmdlet.ShouldProcess('roku-dhcp-watchdog','register SYSTEM task every 1 min')){
    $a=New-ScheduledTaskAction -Execute powershell.exe -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Action Watchdog"
    $t=New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName roku-dhcp-watchdog -Action $a -Trigger $t -User SYSTEM -RunLevel Highest -Force | Out-Null; Log 'Watchdog registered' }
}

switch($Action){
  'Menu' { while($true){ Write-Host "`n1 Discover  2 Install  3 Status  4 Test  5 Rollback  6 Dry-run Install  Q Quit"; switch((Read-Host 'Choose').ToUpper()){
      '1'{Discover|Out-Null} '2'{Install} '3'{Status} '4'{Test} '5'{Rollback} '6'{$WhatIfPreference=$true; Install; $WhatIfPreference=$false} 'Q'{return} } } }
  'Discover'{ Discover | Out-Null } 'Install'{ Install } 'Status'{ Status } 'Test'{ Test }
  'Rollback'{ Rollback } 'Watchdog'{ Watchdog } 'RegisterWatchdog'{ RegisterWatchdog }
}
