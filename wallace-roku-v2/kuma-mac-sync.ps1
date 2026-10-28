<#
  kuma-mac-sync.ps1 - keep Uptime Kuma device monitors pointed at the device's CURRENT DHCP lease on the WALLACE hotspot.
  Devices are identified by MAC (config.json KumaMacMonitors: monitorId -> MAC). If a MAC shows up at a new IP
  (ARP table, after a light ping of the hotspot subnet when unknown), only monitor.hostname is updated in kuma.db
  (never the user table) and Kuma is restarted once so it reloads. No admin needed. -WhatIf = report only.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param([switch]$Quiet)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')
$C = Get-WRConfig
function L([string]$m, [string]$lvl = 'INFO') { Write-WRLog -Message $m -Level $lvl -Name 'kuma-mac-sync' -Config $C -Echo:(-not $Quiet) }
$map = $C.KumaMacMonitors; if (-not $map) { L 'no KumaMacMonitors in config'; exit 0 }
$db = $C.KumaDb; $sq = (Get-Command sqlite3.exe -EA SilentlyContinue).Source
if (-not $sq -or -not (Test-Path -LiteralPath $db)) { L "sqlite3 or kuma.db missing" 'WARN'; exit 0 }
function Norm([string]$m) { ($m -replace '[^0-9A-Fa-f]', '').ToUpper() }
function ArpMap { $h = @{}; Get-NetNeighbor -AddressFamily IPv4 -EA SilentlyContinue | ? { $_.LinkLayerAddress -and $_.LinkLayerAddress -ne '00-00-5E-00-53-06' -and $_.State -ne 'Unreachable' -and $_.IPAddress -like '192.168.*' } | % { $h[(Norm $_.LinkLayerAddress)] = $_.IPAddress }; $h }
$arp = ArpMap
$want = @($map.PSObject.Properties | % { Norm $_.Value })
if (@($want | ? { -not $arp.ContainsKey($_) }).Count) {
    # light async sweep of the hotspot /24 to populate ARP (about 1.5 s)
    $pre = ($C.HotspotIp -replace '\.\d+$', '.')
    $tasks = 2..254 | % { (New-Object Net.NetworkInformation.Ping).SendPingAsync("$pre$_", 600) }
    try { [void][Threading.Tasks.Task]::WaitAll($tasks, 3000) } catch { }
    $arp = ArpMap
}
$changed = 0
foreach ($p in $map.PSObject.Properties) {
    $id = [int]$p.Name; $mac = Norm $p.Value
    $cur = (& $sq -readonly $db "select hostname from monitor where id=$id;" 2>$null | Out-String).Trim()
    $ip = $arp[$mac]
    if (-not $ip) { L "monitor $id MAC $($p.Value): not on network now (keeping $cur)"; continue }
    if ($ip -eq $cur) { continue }
    if ($PSCmdlet.ShouldProcess("monitor $id", "hostname $cur -> $ip")) {
        & $sq $db "update monitor set hostname='$ip' where id=$id;" 2>&1 | Out-Null
        L "monitor $id MAC $($p.Value): $cur -> $ip" 'REPAIR'; $changed++
    }
}
if ($changed -and -not $WhatIfPreference) {
    $k = Get-CimInstance Win32_Process -Filter "name='node.exe'" | ? { $_.CommandLine -match '\s"?server\\server\.js"?\s*$' }
    $k | % { Stop-Process -Id $_.ProcessId -Force }
    Start-Sleep 2; Start-Process wscript.exe -ArgumentList "`"$($C.KumaLauncher)`""
    L "restarted Uptime Kuma to load $changed new device IP(s)"
}
exit 0