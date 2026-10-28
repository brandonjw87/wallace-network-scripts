<#
  lib.ps1 - shared module for the WALLACE hotspot (v2 engine) (dot-source it:  . "$PSScriptRoot\lib.ps1")
  Requires Windows PowerShell 5.1 (WinRT projection is not available in PowerShell 7).
  Contents:
    Config ............ Get-WRConfig
    Logging ........... Write-WRLog (size-based rotation), Write-WRJson (atomic), Read-WRJson
    Helpers ........... Test-WRAdmin, Get-WRServiceState, Test-WRTcp, Test-WRInternet
    Uplinks ........... Get-WRUplinkAliases, Get-WRUplinks, Get-WRActiveUplink (lowest-metric adapter with a gateway),
                        Get-WRNonLoopbackUplinks, Get-WRHotspotUplinkFile (which uplink the hotspot was started on)
    WinRT tethering ... Initialize-WRWinRT, Wait-WRAsyncOp, Wait-WRAsyncAction, Get-WRTetheringManager,
                        Get-WRTetheringInfo
    DNS ............... Resolve-WRDns, Test-WRDnsProbe (resolve a normal domain + confirm an ad domain is blocked)
    Health ............ Get-WRHealth (one object used by watchdog.ps1 and status.ps1)
  SECURITY: nothing in here ever reads or prints the hotspot passphrase or AdGuard credentials.
#>
Set-StrictMode -Version 2.0

$script:WRRoot = $PSScriptRoot
$script:WRWinRTReady = $false

# ------------------------------------------------------------------ config
function Get-WRConfig {
    param([string]$Path = (Join-Path $script:WRRoot 'config.json'))
    if (-not (Test-Path -LiteralPath $Path)) { throw "config not found: $Path" }
    $c = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if (-not (Test-Path -LiteralPath $c.LogDir)) {
        New-Item -ItemType Directory -Path $c.LogDir -Force -WhatIf:$false | Out-Null
    }
    return $c
}

# ------------------------------------------------------------------ logging
function Write-WRLog {
    <# Appends "timestamp [LEVEL] message" to LogDir\<Name>.log, rotating at LogMaxKB (keeps LogKeep old files). #>
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','REPAIR','OK')][string]$Level = 'INFO',
        [string]$Name = 'wallace-roku',
        [psobject]$Config,
        [switch]$Echo
    )
    if (-not $Config) { $Config = Get-WRConfig }
    $log = Join-Path $Config.LogDir "$Name.log"
    try {
        if ((Test-Path -LiteralPath $log) -and ((Get-Item -LiteralPath $log).Length -gt ($Config.LogMaxKB * 1KB))) {
            for ($i = [int]$Config.LogKeep - 1; $i -ge 1; $i--) {
                $src = "$log.$i"; $dst = "$log.$($i + 1)"
                if (Test-Path -LiteralPath $src) { Move-Item -LiteralPath $src -Destination $dst -Force -WhatIf:$false }
            }
            Move-Item -LiteralPath $log -Destination "$log.1" -Force -WhatIf:$false
        }
    } catch { }
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 's'), $Level, $Message
    try { Add-Content -LiteralPath $log -Value $line -Encoding UTF8 -WhatIf:$false } catch { }
    if ($Echo) { Write-Host $line }
}

function Write-WRJson {
    <# Atomic JSON write (temp file + move) so readers never see a half-written file. #>
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string]$Path)
    $tmp = "$Path.tmp"
    [IO.File]::WriteAllText($tmp, ($Object | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))  # no BOM
    Move-Item -LiteralPath $tmp -Destination $Path -Force -WhatIf:$false
}

function Read-WRJson {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json) } catch { return $null }
}

# ------------------------------------------------------------------ helpers
function Test-WRAdmin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-WRServiceState {
    param([Parameter(Mandatory)][string]$Name)
    $s = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $s) { return 'Missing' }
    return [string]$s.Status
}

function Test-WRTcp {
    <# TCP connect with a real timeout (Test-NetConnection is slow and noisy). #>
    param([string]$TargetHost, [int]$Port, [int]$TimeoutMs = 3000)
    $c = New-Object Net.Sockets.TcpClient
    try {
        $ar = $c.BeginConnect($TargetHost, $Port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $c.EndConnect($ar); return $true
    } catch { return $false } finally { $c.Close() }
}

function Test-WRInternet {
    <# True if ANY upstream target answers a TCP connect (IP literals, so it does not depend on DNS). #>
    param([psobject]$Config)
    foreach ($t in $Config.Probe.InternetTargets) {
        $h, $p = $t -split ':'
        if (Test-WRTcp -TargetHost $h -Port ([int]$p) -TimeoutMs ($Config.Probe.TimeoutSec * 1000)) { return $true }
    }
    return $false
}

# ------------------------------------------------------------------ uplinks
function Get-WRUplinkAliases {
    <# UplinkAliases from config (Ethernet, Wi-Fi), falling back to the legacy WifiAlias. #>
    param([psobject]$Config)
    if ($Config.PSObject.Properties['UplinkAliases'] -and @($Config.UplinkAliases).Count) { return @($Config.UplinkAliases) }
    return @($Config.WifiAlias)
}

function Get-WRUplinks {
    <#
      Connected adapters (from UplinkAliases) that have an IPv4 default gateway, sorted by effective
      metric (route + interface metric, as Windows does). The first one is the active internet uplink.
    #>
    param([Parameter(Mandatory)][psobject]$Config)
    $aliases = Get-WRUplinkAliases $Config
    $list = @()
    foreach ($r in @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
        if ($r.NextHop -eq '0.0.0.0' -or $aliases -notcontains $r.InterfaceAlias) { continue }
        $ad = Get-NetAdapter -InterfaceIndex $r.InterfaceIndex -ErrorAction SilentlyContinue
        $ipif = Get-NetIPInterface -InterfaceIndex $r.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        if (-not $ad -or [string]$ad.Status -ne 'Up' -or -not $ipif -or [string]$ipif.ConnectionState -ne 'Connected') { continue }
        $list += [pscustomobject]@{
            Alias = [string]$r.InterfaceAlias; Index = [int]$r.InterfaceIndex; Gateway = [string]$r.NextHop
            Metric = [int]$r.RouteMetric + [int]$ipif.InterfaceMetric; Guid = [string]$ad.InterfaceGuid; LinkSpeed = [string]$ad.LinkSpeed
        }
    }
    return @($list | Sort-Object Metric, Alias)
}

function Get-WRActiveUplink {
    param([Parameter(Mandatory)][psobject]$Config)
    $u = @(Get-WRUplinks $Config)
    if ($u.Count) { return $u[0] }
    return $null
}

function Get-WRHotspotUplinkFile { param([psobject]$Config) Join-Path $Config.LogDir 'hotspot-uplink.json' }

# ------------------------------------------------------------------ WinRT tethering
function Initialize-WRWinRT {
    if ($script:WRWinRTReady) { return }
    if ($PSVersionTable.PSEdition -eq 'Core') { throw 'WinRT tethering needs Windows PowerShell 5.1 (powershell.exe), not pwsh.' }
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $null = [Windows.Networking.Connectivity.NetworkInformation, Windows.Networking.Connectivity, ContentType = WindowsRuntime]
    $null = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager, Windows.Networking.NetworkOperators, ContentType = WindowsRuntime]
    $m = [System.WindowsRuntimeSystemExtensions].GetMethods()
    $script:WRAsTaskOp = ($m | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
    $script:WRAsTaskAct = ($m | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction' })[0]
    $script:WRWinRTReady = $true
}

function Wait-WRAsyncOp {
    param($Operation, [Type]$ResultType, [int]$TimeoutSec = 30)
    $task = $script:WRAsTaskOp.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    if (-not $task.Wait($TimeoutSec * 1000)) { throw "WinRT operation timed out after ${TimeoutSec}s" }
    return $task.Result
}

function Wait-WRAsyncAction {
    param($Action, [int]$TimeoutSec = 30)
    $task = $script:WRAsTaskAct.Invoke($null, @($Action))
    if (-not $task.Wait($TimeoutSec * 1000)) { throw "WinRT action timed out after ${TimeoutSec}s" }
}

function Get-WRTetheringManager {
    <#
      Returns the tethering manager bound to the active uplink (lowest-metric adapter with a default gateway,
      Ethernet or Wi-Fi), or $null if there is no uplink. Sets $script:WRBoundUplink to the alias it used.
      Falls back to Windows' internet profile, then to any WLAN/Ethernet profile with internet access.
    #>
    param([psobject]$Config)
    Initialize-WRWinRT
    if (-not $Config) { $Config = Get-WRConfig }
    $NI = [Windows.Networking.Connectivity.NetworkInformation]
    $script:WRBoundUplink = ''
    $p = $null
    $up = Get-WRActiveUplink $Config
    if ($up) {
        foreach ($cp in $NI::GetConnectionProfiles()) {
            try {
                if ($cp.NetworkAdapter -and ([guid]$cp.NetworkAdapter.NetworkAdapterId) -eq ([guid]$up.Guid)) { $p = $cp; $script:WRBoundUplink = $up.Alias; break }
            } catch { }
        }
    }
    if (-not $p) { $p = $NI::GetInternetConnectionProfile(); if ($p -and $up) { $script:WRBoundUplink = $up.Alias } }
    if (-not $p) {
        # Fallback: any profile that still reports internet access (GetInternetConnectionProfile can blink to null).
        foreach ($cp in $NI::GetConnectionProfiles()) {
            try {
                if ([string]$cp.GetNetworkConnectivityLevel() -eq 'InternetAccess') { $p = $cp; break }
            } catch { }
        }
    }
    if (-not $p) { return $null }
    return [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile($p)
}

function Get-WRTetheringInfo {
    param([psobject]$Config)
    $o = [ordered]@{ State = 'Unknown'; Ssid = ''; Band = ''; ClientCount = 0; MaxClientCount = 0; Clients = @(); Error = '' }
    try {
        $mgr = Get-WRTetheringManager -Config $Config
        if (-not $mgr) { $o.State = 'NoUplink'; return [pscustomobject]$o }
        $o.State = [string]$mgr.TetheringOperationalState
        $ap = $mgr.GetCurrentAccessPointConfiguration()
        $o.Ssid = [string]$ap.Ssid
        try { $o.Band = [string]$ap.Band } catch { $o.Band = 'n/a' }
        $o.ClientCount = [int]$mgr.ClientCount
        $o.MaxClientCount = [int]$mgr.MaxClientCount
        $list = @()
        try {
            foreach ($cl in $mgr.GetTetheringClients()) {
                $names = @($cl.HostNames | ForEach-Object { $_.DisplayName })
                $list += [pscustomobject]@{ Mac = [string]$cl.MacAddress; Names = ($names -join ' ') }
            }
        } catch { }
        $o.Clients = $list
    } catch { $o.State = 'Error'; $o.Error = $_.Exception.Message }
    return [pscustomobject]$o
}

# ------------------------------------------------------------------ DNS
function Resolve-WRDns {
    <# Queries one server directly (no hosts file, no cache). Returns Ok/NxDomain/Ips/Error. #>
    param([string]$Server, [string]$Name)
    $r = [ordered]@{ Server = $Server; Name = $Name; Ok = $false; NxDomain = $false; Ips = @(); Error = '' }
    try {
        $ans = Resolve-DnsName -Name $Name -Server $Server -Type A -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction Stop
        $r.Ips = @($ans | Where-Object { $_.PSObject.Properties['IPAddress'] -and $_.IPAddress } | ForEach-Object { [string]$_.IPAddress })
        $r.Ok = $true
    } catch {
        $msg = $_.Exception.Message
        if ($msg -match 'does not exist|NXDOMAIN|9003') { $r.NxDomain = $true; $r.Ok = $true } else { $r.Error = ($msg -split "`n")[0].Trim() }
    }
    return [pscustomobject]$r
}

function Test-WRDnsProbe {
    <# Resolves = normal domain gets a real IP. Blocks = ad domain returns 0.0.0.0 / :: / NXDOMAIN / empty. #>
    param([string]$Server, [psobject]$Config)
    $good = Resolve-WRDns -Server $Server -Name $Config.Probe.GoodDomain
    $ad = Resolve-WRDns -Server $Server -Name $Config.Probe.AdDomain
    $resolves = $good.Ok -and -not $good.NxDomain -and (@($good.Ips | Where-Object { $_ -ne '0.0.0.0' }).Count -gt 0)
    $blocks = $ad.Ok -and ($ad.NxDomain -or @($ad.Ips | Where-Object { $_ -notin @('0.0.0.0', '::', '127.0.0.1') }).Count -eq 0)
    $detail = '{0}->{1}; {2}->{3}' -f $Config.Probe.GoodDomain, $(if ($good.Ok) { ($good.Ips -join ',') } else { "ERR $($good.Error)" }),
        $Config.Probe.AdDomain, $(if ($ad.NxDomain) { 'NXDOMAIN' } elseif ($ad.Ok) { ($ad.Ips -join ',') } else { "ERR $($ad.Error)" })
    return [pscustomobject]@{ Server = $Server; Resolves = [bool]$resolves; Blocks = [bool]$blocks; Detail = $detail }
}

# ------------------------------------------------------------------ health
function New-WRCheck {
    param([string]$Name, [string]$Component, [bool]$Ok, [string]$Detail, [ValidateSet('Critical','Warn','Info')][string]$Severity = 'Critical')
    [pscustomobject]@{ Name = $Name; Component = $Component; Ok = $Ok; Severity = $Severity; Detail = $Detail }
}

function Get-WRNonLoopbackUplinks {
    <# Aliases of uplink adapters whose first IPv4 DNS server is not 127.0.0.1. #>
    param([psobject]$Config, $Uplinks)
    if ($null -eq $Uplinks) { $Uplinks = @(Get-WRUplinks $Config) }
    foreach ($u in @($Uplinks)) {
        $dns = @((Get-DnsClientServerAddress -InterfaceIndex $u.Index -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)
        if (-not ($dns.Count -gt 0 -and $dns[0] -eq '127.0.0.1')) { $u.Alias }
    }
}

function Get-WRHealth {
    <#
      Components: Uplink, Hotspot, AdGuard, HotspotDns, Dhcp, Apps.
      Critical failures drive watchdog repairs; Warn/Info are reported only.
    #>
    param([psobject]$Config, [switch]$IncludeApps)
    $C = $Config
    $checks = New-Object System.Collections.ArrayList

    # Uplink / internet
    $inet = Test-WRInternet -Config $C
    [void]$checks.Add((New-WRCheck 'Internet' 'Uplink' $inet $(if ($inet) { 'upstream TCP reachable' } else { 'no upstream reachable' })))
    $uplinks = @(Get-WRUplinks $C)
    $active = if ($uplinks.Count) { $uplinks[0] } else { $null }
    [void]$checks.Add((New-WRCheck 'ActiveUplink' 'Uplink' ([bool]$active) $(if ($active) { "$($active.Alias) ($($active.LinkSpeed), metric $($active.Metric)); all: " + (($uplinks | ForEach-Object { "$($_.Alias)=$($_.Metric)" }) -join ' ') } else { 'no adapter with a default gateway' }) 'Warn'))
    # LAN IP is uplink-aware: Ethernet should hold LanIps.Ethernet (.229), Wi-Fi LanIps.Wi-Fi (.210, DHCP reservation).
    $lanMap = @{}; if ($C.PSObject.Properties['LanIps']) { foreach ($p in $C.LanIps.PSObject.Properties) { $lanMap[$p.Name] = [string]$p.Value } } else { $lanMap[[string]$C.WifiAlias] = [string]$C.LanIp }
    $lanHit = $null; $lanAlias = if ($active) { $active.Alias } else { $null }
    if ($lanAlias -and $lanMap.ContainsKey($lanAlias)) { $lanHit = @(Get-NetIPAddress -InterfaceAlias $lanAlias -AddressFamily IPv4 -IPAddress $lanMap[$lanAlias] -ErrorAction SilentlyContinue)[0] }
    if (-not $lanHit) { foreach ($k in $lanMap.Keys) { $x = @(Get-NetIPAddress -InterfaceAlias $k -AddressFamily IPv4 -IPAddress $lanMap[$k] -ErrorAction SilentlyContinue)[0]; if ($x) { $lanHit = $x; break } } }
    [void]$checks.Add((New-WRCheck 'LanIp' 'Uplink' ([bool]$lanHit) $(if ($lanHit) { "$($lanHit.IPAddress) on $($lanHit.InterfaceAlias)" + $(if ($lanAlias -and $lanHit.InterfaceAlias -ne $lanAlias) { " (active uplink is $lanAlias)" } else { '' }) } else { 'expected LAN IP not found (' + (($lanMap.Keys | ForEach-Object { "$_=$($lanMap[$_])" }) -join ', ') + ')' }) 'Warn'))

    # Hotspot
    $t = Get-WRTetheringInfo -Config $C
    $tOk = ($t.State -eq 'On')
    [void]$checks.Add((New-WRCheck 'Tethering' 'Hotspot' $tOk ("state={0} ssid={1} band={2} clients={3}/{4} {5}" -f $t.State, $t.Ssid, $t.Band, $t.ClientCount, $t.MaxClientCount, $t.Error).Trim()))
    $ssidOk = ($t.Ssid -eq $C.Ssid)
    [void]$checks.Add((New-WRCheck 'Ssid' 'Hotspot' $ssidOk "configured SSID '$($t.Ssid)'" 'Warn'))
    $hsIp = [bool](Get-NetIPAddress -IPAddress $C.HotspotIp -ErrorAction SilentlyContinue)
    [void]$checks.Add((New-WRCheck 'HotspotIp' 'Hotspot' $hsIp "$($C.HotspotIp) present=$hsIp"))
    foreach ($s in $C.IcsServices) {
        $st = Get-WRServiceState $s
        [void]$checks.Add((New-WRCheck "Svc:$s" 'Hotspot' ($st -eq 'Running') $st))
    }
    # Failover: ICS shares the adapter that was the uplink when tethering started. If that changed
    # (e.g. Ethernet unplugged -> Wi-Fi), the hotspot must be restarted to re-bind. Unknown = ok.
    $bound = Read-WRJson (Get-WRHotspotUplinkFile $C)
    $boundAlias = if ($bound -and $bound.PSObject.Properties['Alias']) { [string]$bound.Alias } else { '' }
    $bindOk = (-not $tOk) -or (-not $active) -or (-not $boundAlias) -or ($boundAlias -eq $active.Alias)
    [void]$checks.Add((New-WRCheck 'HotspotUplink' 'Hotspot' $bindOk ("shared={0} active={1}" -f $(if ($boundAlias) { $boundAlias } else { 'unknown' }), $(if ($active) { $active.Alias } else { 'none' }))))
    $icsDhcp = [bool](Get-NetUDPEndpoint -LocalAddress $C.HotspotIp -LocalPort 67 -ErrorAction SilentlyContinue)
    [void]$checks.Add((New-WRCheck 'IcsDhcp67' 'Hotspot' $icsDhcp "ICS DHCP listening on $($C.HotspotIp):67=$icsDhcp" 'Warn'))

    # AdGuard Home
    $agh = Get-WRServiceState $C.AdGuardService
    [void]$checks.Add((New-WRCheck "Svc:$($C.AdGuardService)" 'AdGuard' ($agh -eq 'Running') $agh))
    $p127 = Test-WRDnsProbe -Server '127.0.0.1' -Config $C
    [void]$checks.Add((New-WRCheck 'Dns127:resolve' 'AdGuard' $p127.Resolves $p127.Detail))
    [void]$checks.Add((New-WRCheck 'Dns127:block' 'AdGuard' $p127.Blocks $p127.Detail))

    # What hotspot clients actually get: ICS DNS proxy on 192.0.2.11 forwards to the uplink adapter's DNS servers.
    $pHs = $null
    if ($hsIp) {
        $pHs = Test-WRDnsProbe -Server $C.HotspotIp -Config $C
        [void]$checks.Add((New-WRCheck 'DnsHotspot:resolve' 'HotspotDns' $pHs.Resolves $pHs.Detail))
        [void]$checks.Add((New-WRCheck 'DnsHotspot:block' 'HotspotDns' $pHs.Blocks $pHs.Detail))
    }
    # Every adapter with a default gateway must use 127.0.0.1 first: any of them can become the uplink ICS forwards to.
    $nonLoop = @(Get-WRNonLoopbackUplinks $C $uplinks)
    $dnsDetail = @($uplinks | ForEach-Object { "$($_.Alias)=" + (@((Get-DnsClientServerAddress -InterfaceIndex $_.Index -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses) -join ',') }) -join '; '
    if (-not $dnsDetail) { $dnsDetail = 'no uplink adapters' }
    [void]$checks.Add((New-WRCheck 'UplinkDnsLoopback' 'HotspotDns' ($nonLoop.Count -eq 0) ("IPv4 DNS: $dnsDetail" + $(if ($nonLoop.Count) { "  (not loopback: $($nonLoop -join ','))" } else { '' })) 'Warn'))

    # Main-LAN Roku DHCP (Open DHCP Server). Warn only: it cannot bind unless the PC has a STATIC LAN IP.
    $d = Get-WRServiceState $C.DhcpService
    [void]$checks.Add((New-WRCheck "Svc:$($C.DhcpService)" 'Dhcp' ($d -eq 'Running') $d 'Warn'))
    $iniStale = $false
    try { $iniStale = [bool](Select-String -LiteralPath $C.DhcpIni -SimpleMatch $C.StaleLanIp -Quiet -ErrorAction Stop) } catch { }
    [void]$checks.Add((New-WRCheck 'DhcpIniIp' 'Dhcp' (-not $iniStale) $(if ($iniStale) { "ini still references $($C.StaleLanIp)" } else { 'ini ok' }) 'Warn'))

    if ($IncludeApps) {
        foreach ($kv in @(,@('AdGuardWeb', $C.Ports.AdGuardWeb))) {
            $ok = Test-WRTcp -TargetHost '127.0.0.1' -Port $kv[1] -TimeoutMs 1500
            [void]$checks.Add((New-WRCheck "Port:$($kv[0])" 'Apps' $ok "127.0.0.1:$($kv[1]) listening=$ok" 'Info'))
        }
        $wt = Get-ScheduledTask -TaskName $C.Watchdog.TaskName -ErrorAction SilentlyContinue
        $wtArgs = ''; if ($wt) { $wtArgs = [string]$wt.Actions[0].Arguments }
        $v2 = $wtArgs -match 'wallace-roku-v2'
        [void]$checks.Add((New-WRCheck 'Task:Watchdog' 'Apps' $v2 $(if ($wt) { "$($wt.State) -> " + $(if ($v2) { 'v2' } else { 'LEGACY script' }) } else { 'missing' }) 'Info'))
    }

    $crit = @($checks | Where-Object { $_.Severity -eq 'Critical' -and -not $_.Ok })
    [pscustomobject]@{
        Time          = (Get-Date -Format 's')
        Healthy       = ($crit.Count -eq 0)
        FailedCritical = @($crit | ForEach-Object { $_.Name })
        Tethering     = $t
        Checks        = @($checks)
    }
}

function Test-WRComponentOk {
    param($Health, [string]$Component)
    return (@($Health.Checks | Where-Object { $_.Component -eq $Component -and $_.Severity -eq 'Critical' -and -not $_.Ok }).Count -eq 0)
}
