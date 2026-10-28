<#
 Wallace-Roku hotspot upgrade. Run once from an admin PowerShell (self-elevates if not admin).
   .\hotspot-upgrade.ps1            apply all steps
   .\hotspot-upgrade.ps1 -WhatIf    show what would change, change nothing
   .\hotspot-upgrade.ps1 -Rollback  undo firewall rules, task, service start types, adapter settings
   -SkipDriver                       skip the Intel driver install
 Idempotent; each step independent (try/catch). Log: hotspot-upgrade.log. State for rollback: hotspot-upgrade.state.json
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param([switch]$Rollback,[switch]$SkipDriver)

$ErrorActionPreference = 'Stop'
$Dir      = 'C:\Users\YOU\Tools\roku-dhcp'
$Log      = Join-Path $Dir 'hotspot-upgrade.log'
$StateF   = Join-Path $Dir 'hotspot-upgrade.state.json'
$Driver   = Join-Path $Dir 'drivers\WiFi-24.80.0-Driver64-Win10-Win11.exe'
$DriverSha= '14b12299d6df2acb499de1d44d9243bb2bc4c050c1876af5abfd06c0b64100c33e357c8c9b2d587dd0792229029cb75797dfd33ffb3eb09b506ad787a611bece'
$TargetDrv= '24.80.0.2'
$AgYaml   = 'C:\Users\YOU\Tools\AdGuardHome\AdGuardHome.yaml'
$TaskName = 'Wallace-Roku Watchdog'
$RulePfx  = 'Wallace-Roku DNS-bypass block'
$WifiName = 'Wi-Fi'
$WI       = [bool]$WhatIfPreference
$WhatIfPreference=$false; Import-Module CimCmdlets,NetAdapter,NetSecurity,ScheduledTasks,DnsClient -EA SilentlyContinue; $WhatIfPreference=$WI

function L($m,[string]$lvl='INFO'){ $line="$(Get-Date -f s) [$lvl] $(if($WI){'[WhatIf] '})$m"; Write-Host $line; try{ Add-Content -Path $Log -Value $line -WhatIf:$false }catch{} }

# ---- self-elevate ----
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $WI) {
  $a = @('-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File',"`"$PSCommandPath`"")
  if ($Rollback){$a+='-Rollback'}; if ($SkipDriver){$a+='-SkipDriver'}
  Start-Process powershell.exe -Verb RunAs -ArgumentList $a; exit
}
if (-not $isAdmin) { L 'Not admin: WhatIf preview only (some reads may be denied).' 'WARN' }

$State = @{}; if (Test-Path $StateF) { try { $o=Get-Content $StateF -Raw | ConvertFrom-Json; $o.psobject.Properties | % { $v=$_.Value; if($v -is [psobject] -and $v -isnot [string] -and $v.psobject.Properties.Count){ $h=@{}; $v.psobject.Properties | % { $h[$_.Name]=$_.Value }; $v=$h }; $State[$_.Name]=$v } } catch {} }
function Save-State { if (-not $WI) { $State | ConvertTo-Json -Depth 5 | Set-Content $StateF } }

$Adv = [ordered]@{ 'MIMOPowerSaveMode'='No SMPS'; 'RoamAggressiveness'='1. Lowest'; 'RoamingPreferredBandType'='3. Prefer 5GHz band'; '*WakeOnMagicPacket'='Disabled'; '*WakeOnPattern'='Disabled' }
function Get-WifiClassKey { $g=(Get-NetAdapter -Name $WifiName).InterfaceGuid; Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}' -EA SilentlyContinue | ? { (Get-ItemProperty $_.PSPath -EA SilentlyContinue).NetCfgInstanceId -eq $g } | select -First 1 }
function Start-Hotspot { if ($WI) { L 'would run start-hotspot.ps1 (HS_RECONF=1)'; return }; $env:HS_RECONF='1'; try { $o = & (Join-Path $Dir 'start-hotspot.ps1') 2>&1 | Out-String; L ("start-hotspot: "+($o -replace '\s+',' ').Trim()) } finally { Remove-Item Env:HS_RECONF -EA SilentlyContinue } }

# ======================= ROLLBACK =======================
if ($Rollback) {
  L '=== ROLLBACK start ==='
  try { Get-NetFirewallRule -DisplayName "$RulePfx*" -EA SilentlyContinue | % { if($PSCmdlet.ShouldProcess($_.DisplayName,'Remove firewall rule')){ Remove-NetFirewallRule -Name $_.Name }; L "removed rule $($_.DisplayName)" } } catch { L "fw rollback: $_" 'ERR' }
  try { if (Get-ScheduledTask -TaskName $TaskName -EA SilentlyContinue) { if($PSCmdlet.ShouldProcess($TaskName,'Unregister task')){ Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false }; L "removed task $TaskName" } } catch { L "task rollback: $_" 'ERR' }
  try { foreach($s in 'icssvc','SharedAccess'){ $v = if($State.svc -and $State.svc.$s){$State.svc.$s}else{'Manual'}; if($PSCmdlet.ShouldProcess($s,"StartupType $v")){ Set-Service $s -StartupType $v }; L "$s -> $v" } } catch { L "svc rollback: $_" 'ERR' }
  try { if ($State.adv) { foreach($p in $State.adv.psobject.Properties){ if($PSCmdlet.ShouldProcess($p.Name,"restore '$($p.Value)'")){ Set-NetAdapterAdvancedProperty -Name $WifiName -RegistryKeyword $p.Name -DisplayValue $p.Value -NoRestart }; L "adv $($p.Name) -> $($p.Value)" } } } catch { L "adv rollback: $_" 'ERR' }
  try { if ($null -ne $State.pnp) { $k=Get-WifiClassKey; if($k -and $PSCmdlet.ShouldProcess('PnPCapabilities',"restore $($State.pnp)")){ if($State.pnp -eq -1){ Remove-ItemProperty $k.PSPath PnPCapabilities -EA SilentlyContinue } else { Set-ItemProperty $k.PSPath PnPCapabilities ([int]$State.pnp) -Type DWord } }; L "PnPCapabilities -> $($State.pnp) (reboot to apply)" } } catch { L "pnp rollback: $_" 'ERR' }
  try { if(-not $WI){ Restart-NetAdapter -Name $WifiName; Start-Sleep 15 }; Start-Hotspot } catch { L "restart: $_" 'ERR' }
  L 'Driver is NOT rolled back automatically (Device Manager > Roll Back Driver if needed).'
  L '=== ROLLBACK done ==='; exit
}

L '=== UPGRADE start ==='
if (-not $State.svc) { $State.svc = @{} }

# ---- (a) Intel driver ----
try {
  if ($SkipDriver) { L 'a) driver: skipped (-SkipDriver)' }
  else {
    $cur = (Get-NetAdapter -Name $WifiName).DriverVersion
    if ([version]$cur -ge [version]$TargetDrv) { L "a) driver: already $cur (>= $TargetDrv), skip" }
    elseif (-not (Test-Path $Driver)) { L "a) driver: file missing $Driver" 'ERR' }
    elseif ((& { $fs=[IO.File]::OpenRead($Driver); try { -join ([Security.Cryptography.SHA512]::Create().ComputeHash($fs) | % { $_.ToString('x2') }) } finally { $fs.Close() } }) -ne $DriverSha) { L 'a) driver: SHA512 mismatch, NOT installing' 'ERR' }
    elseif ((Get-AuthenticodeSignature $Driver).Status -ne 'Valid') { L 'a) driver: signature invalid, NOT installing' 'ERR' }
    elseif ($PSCmdlet.ShouldProcess("Intel Wi-Fi $cur -> $TargetDrv",'Silent install (Wi-Fi + hotspot drop ~1 min)')) {
      L "a) installing driver (current $cur). Wi-Fi and hotspot will drop briefly."
      $p = Start-Process $Driver -ArgumentList '-q','-s','-l',"`"$Dir\intel-driver-install.log`"" -Wait -PassThru
      L "a) installer exit code $($p.ExitCode)"
      Start-Sleep 30
      $deadline=(Get-Date).AddSeconds(90); while((Get-Date) -lt $deadline -and (Get-NetAdapter -Name $WifiName -EA SilentlyContinue).Status -ne 'Up'){ Start-Sleep 5 }
      L "a) driver now $((Get-NetAdapter -Name $WifiName).DriverVersion)"
      Start-Hotspot
    } else { L "a) would install driver $cur -> $TargetDrv, then re-run start-hotspot.ps1 with HS_RECONF=1" }
  }
} catch { L "a) driver: $_" 'ERR' }

# ---- (b) services Automatic ----
foreach ($s in 'icssvc','SharedAccess') {
  try {
    $svc = Get-CimInstance Win32_Service -Filter "Name='$s'"; $cur = $svc.StartMode -replace '^Auto$','Automatic'
    if (-not $State.svc.$s) { $State.svc.$s = $cur }
    if ($cur -eq 'Automatic') { L "b) $s already Automatic" }
    elseif ($PSCmdlet.ShouldProcess($s,"StartupType $cur -> Automatic")) { Set-Service $s -StartupType Automatic; L "b) $s -> Automatic" }
    else { L "b) would set $s $cur -> Automatic" }
  } catch { L "b) $s : $_" 'ERR' }
}
Save-State

# ---- (c) watchdog task ----
try {
  $wd = Join-Path $Dir 'hotspot-watchdog.ps1'
  if (-not (Test-Path $wd)) { throw "missing $wd" }
  $user = "$env:COMPUTERNAME\Brandon"
  $act  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$wd`""
  $t1   = New-ScheduledTaskTrigger -AtLogOn -User $user
  $t2   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5)
  $prn  = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
  $set  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 4)
  if ($PSCmdlet.ShouldProcess($TaskName,'Register/replace scheduled task (Brandon, Highest, at logon + every 5 min)')) {
    Register-ScheduledTask -TaskName $TaskName -Action $act -Trigger $t1,$t2 -Principal $prn -Settings $set -Force | Out-Null; L "c) task '$TaskName' registered"
  } else { L "c) would register task '$TaskName' -> $wd" }
} catch { L "c) task: $_" 'ERR' }

# ---- (d) adapter tweaks ----
try {
  if (-not $State.adv) { $State.adv = @{} }
  $changed = $false
  foreach ($k in $Adv.Keys) {
    try {
      $p = Get-NetAdapterAdvancedProperty -Name $WifiName -RegistryKeyword $k -EA Stop
      if (-not $State.adv.$k) { $State.adv.$k = $p.DisplayValue }
      if ($p.DisplayValue -eq $Adv[$k]) { L "d) $($p.DisplayName) already '$($Adv[$k])'" }
      elseif ($PSCmdlet.ShouldProcess($p.DisplayName,"'$($p.DisplayValue)' -> '$($Adv[$k])'")) { Set-NetAdapterAdvancedProperty -Name $WifiName -RegistryKeyword $k -DisplayValue $Adv[$k] -NoRestart; $changed=$true; L "d) $($p.DisplayName) -> '$($Adv[$k])'" }
      else { L "d) would set $($p.DisplayName) '$($p.DisplayValue)' -> '$($Adv[$k])'" }
    } catch { L "d) $k : $_" 'ERR' }
  }
  try {
    $key = Get-WifiClassKey
    if (-not $key) { throw 'adapter class key not found' }
    $cur = (Get-ItemProperty $key.PSPath -EA SilentlyContinue).PnPCapabilities; if ($null -eq $cur) { $cur = -1 }
    if ($null -eq $State.pnp) { $State.pnp = $cur }
    if ($cur -eq 24) { L 'd) PnPCapabilities already 24 (power-off disallowed)' }
    elseif ($PSCmdlet.ShouldProcess("PnPCapabilities ($($key.PSChildName))","$cur -> 24")) { Set-ItemProperty $key.PSPath PnPCapabilities 24 -Type DWord; L "d) PnPCapabilities $cur -> 24 (takes effect after reboot)" }
    else { L "d) would set PnPCapabilities $cur -> 24 (disables 'allow computer to turn off device')" }
  } catch { L "d) PnPCapabilities: $_" 'ERR' }
  L 'd) Throughput Booster left Disabled; MTU left default.'
  Save-State
  if ($changed -and -not $WI) { L 'd) restarting Wi-Fi adapter to apply (brief drop)'; Restart-NetAdapter -Name $WifiName; Start-Sleep 15; Start-Hotspot }
} catch { L "d) $_" 'ERR' }

# ---- (e) firewall DNS-bypass block ----
function IpToU([string]$ip){ $b=([Net.IPAddress]::Parse($ip)).GetAddressBytes(); [array]::Reverse($b); [BitConverter]::ToUInt32($b,0) }
function UToIp([uint32]$u){ $b=[BitConverter]::GetBytes($u); [array]::Reverse($b); ([Net.IPAddress]::new($b)).ToString() }
function Get-Complement([string[]]$allow){
  $s = $allow | % { IpToU $_ } | sort -Unique; $r=@(); [int64]$start=0
  foreach($u in $s){ if($u -gt $start){ $r += "$(UToIp ([uint32]$start))-$(UToIp ([uint32]($u-1)))" }; $start=[int64]$u+1 }
  if($start -le 4294967295){ $r += "$(UToIp ([uint32]$start))-255.255.255.255" }; $r
}
try {
  # allowed DNS destinations: loopback range edges handled by excluding whole 127/8 below, hotspot gw, router, AdGuard upstreams
  $allow = [System.Collections.Generic.List[string]]::new()
  '192.0.2.11','192.0.2.15','192.0.2.28' | % { $allow.Add($_) }
  $hosts = @()
  if (Test-Path $AgYaml) {
    $y = Get-Content $AgYaml; $in=$false
    foreach ($line in $y) {
      if ($line -match '^\s*(upstream_dns|bootstrap_dns|fallback_dns|private_networks|local_ptr_upstreams):') { $in=$true; if($line -match '\[(.*)\]'){ $Matches[1] -split ',' | % { $hosts += $_.Trim(" '`"") }; $in=$false }; continue }
      if ($in) { if ($line -match '^\s*-\s*(.+)$') { $hosts += $Matches[1].Trim(" '`"") } elseif ($line -notmatch '^\s*$') { $in=$false } }
    }
  } else { L "e) $AgYaml not readable/found" 'WARN' }
  $v4 = @(); $v6 = $false
  foreach ($h in $hosts) {
    $x = $h -replace '^\[/[^\]]*/\]',''                       # strip [/domain/] prefix
    $x = $x -replace '^(udp|tcp|tls|https|quic|h3|sdns)://',''
    $x = ($x -split '[/#]')[0]
    if ($x -match '^\[?([0-9a-fA-F:]+:[0-9a-fA-F:]*)\]?(:\d+)?$') { $v6=$true; continue }
    $x = $x -replace ':\d+$',''
    if ($x -match '^\d{1,3}(\.\d{1,3}){3}$') { $v4 += $x }
    elseif ($x -and $h -notmatch '^(https|h3)://') {            # DoT/QUIC/plain hostnames: resolve (DoH on 443 unaffected)
      try { (Resolve-DnsName $x -Type A -DnsOnly -EA Stop | ? IPAddress).IPAddress | % { $v4 += $_ } } catch { L "e) could not resolve upstream $x" 'WARN' }
    }
  }
  $v4 | sort -Unique | % { $allow.Add($_) }
  L "e) upstream entries parsed: $($hosts.Count); allowed IPv4 DNS destinations: $(($allow | sort -Unique) -join ', ')"
  if ($hosts.Count -eq 0) { L 'e) no upstreams parsed from AdGuardHome.yaml -> SKIPPING firewall step to avoid breaking AdGuard' 'WARN' }
  else {
    $ranges = Get-Complement (@($allow) + @('127.0.0.0') ) | ? { $_ -notmatch '^127\.' }
    # remove 127.0.0.0/8 entirely from block ranges
    $ranges = foreach($r in $ranges){ $a,$b=$r -split '-'; $ua=IpToU $a; $ub=IpToU $b; $lo=IpToU '127.0.0.0'; $hi=IpToU '127.255.255.255'
      if($ub -lt $lo -or $ua -gt $hi){ $r } else { if($ua -lt $lo){ "$a-$(UToIp ($lo-1))" }; if($ub -gt $hi){ "$(UToIp ($hi+1))-$b" } } }
    if (-not $v6) { $ranges += '2000::/3' }    # block global IPv6 DNS unless an upstream is IPv6
    else { L 'e) IPv6 upstream present: IPv6 not blocked' 'WARN' }
    $defs = foreach($proto in 'TCP','UDP'){ foreach($dir in 'Outbound','Inbound'){ @{ Proto=$proto; Dir=$dir; Name="$RulePfx $dir $proto" } } }
    foreach ($r in $defs) {
      try {
        $existing = Get-NetFirewallRule -DisplayName $r.Name -EA SilentlyContinue
        if ($PSCmdlet.ShouldProcess($r.Name,"Create/replace block rule: remote ports 53,853, $($ranges.Count) remote ranges (all except allowed)")) {
          if ($existing) { Remove-NetFirewallRule -DisplayName $r.Name }
          if ($r.Dir -eq 'Outbound') { New-NetFirewallRule -DisplayName $r.Name -Group 'Wallace-Roku' -Direction Outbound -Action Block -Protocol $r.Proto -RemotePort 53,853 -RemoteAddress $ranges -Profile Any | Out-Null }
          else                       { New-NetFirewallRule -DisplayName $r.Name -Group 'Wallace-Roku' -Direction Inbound  -Action Block -Protocol $r.Proto -RemotePort 53,853 -RemoteAddress $ranges -Profile Any | Out-Null }
          L "e) rule '$($r.Name)' $(if($existing){'replaced'}else{'created'})"
        } else { L "e) would $(if($existing){'replace'}else{'create'}) '$($r.Name)'" }
      } catch { L "e) $($r.Name): $_" 'ERR' }
    }
    if (-not $WI) {
      Start-Sleep 2
      try { Resolve-DnsName example.com -Server 127.0.0.1 -DnsOnly -QuickTimeout -EA Stop | Out-Null; L 'e) self-test: AdGuard (127.0.0.1) still resolves OK' }
      catch { L 'e) self-test FAILED: AdGuard cannot resolve -> removing DNS block rules automatically' 'ERR'; Get-NetFirewallRule -DisplayName "$RulePfx*" | Remove-NetFirewallRule }
      try { Resolve-DnsName example.com -Server 8.8.8.8 -DnsOnly -QuickTimeout -EA Stop | Out-Null; L 'e) note: direct query to 8.8.8.8 still works from PC' 'WARN' } catch { L 'e) direct 8.8.8.8 from PC now blocked (expected)' }
    }
  }
} catch { L "e) firewall: $_ $(if(-not $isAdmin){'(expected without admin: AdGuardHome.yaml/firewall need admin)'})" 'ERR' }

L '=== UPGRADE done. Review log above. Undo with: -Rollback ==='
