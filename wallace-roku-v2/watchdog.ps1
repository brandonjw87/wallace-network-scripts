<#
  watchdog.ps1 (v2) - health check + escalating self-repair for WALLACE hotspot + AdGuard Home.
  Run by scheduled task 'WALLACE Watchdog' (Brandon, Highest, every few minutes + at logon).
  Usage:
    .\watchdog.ps1              # normal: quiet when healthy, repairs when not
    .\watchdog.ps1 -CheckOnly   # (or -WhatIf) report only, change nothing, print the health table
  Repair ladder (each step only if the previous one did not fix it; re-checks in between):
    L1 targeted : start/restart only what is broken (AdGuardHome, ICS services, OpenDHCPServer),
                  re-assert DNS -> 127.0.0.1 on EVERY uplink adapter with a gateway (Ethernet + Wi-Fi; needs admin;
                  ICS forwards hotspot DNS to the active uplink's DNS), start tethering if Off,
                  failover: start-hotspot -Restart if the active uplink changed (e.g. Ethernet unplugged)
    L2 ICS      : restart SharedAccess + icssvc, then start-hotspot.ps1          (gated by cooldown)
    L3 hotspot  : start-hotspot.ps1 -Restart (stop + start tethering)             (gated by cooldown)
  No repairs while the uplink itself is down (nothing to share; avoids restart loops).
  Writes logs\status.json every run, logs only on problems/recoveries.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param([switch]$CheckOnly)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib.ps1')
$C = Get-WRConfig
$Dry = $CheckOnly -or $WhatIfPreference
function L([string]$m, [string]$lvl = 'INFO') { Write-WRLog -Message $m -Level $lvl -Name 'watchdog' -Config $C -Echo:$Dry }
function Summ($h) { if ($h.Healthy) { 'healthy' } else { 'FAILED: ' + ($h.FailedCritical -join ',') } }

# single-instance guard (task may overlap with a manual run)
$mutex = New-Object Threading.Mutex($false, 'Global\WallaceRokuV2Watchdog')
if (-not $mutex.WaitOne(0)) { exit 0 }
try {
    $now = Get-Date
    $raw = Read-WRJson $C.StateFile
    $st = [pscustomobject]@{ FailCount = 0; LastEscalation = ''; LastNag = ''; LastRepair = '' }
    if ($raw) { foreach ($pn in 'FailCount', 'LastEscalation', 'LastNag', 'LastRepair') { if ($raw.PSObject.Properties[$pn]) { $st.$pn = $raw.$pn } } }
    $h = Get-WRHealth -Config $C
    $isAdmin = Test-WRAdmin

    if ($Dry) {
        Write-Host ("WALLACE watchdog CHECK-ONLY  {0}  admin={1}  failcount={2}" -f $h.Time, $isAdmin, $st.FailCount)
        $h.Checks | Format-Table @{n = 'OK'; e = { if ($_.Ok) { 'ok' } else { 'FAIL' } } }, Severity, Component, Name, Detail -AutoSize -Wrap | Out-String -Width 220 | Write-Host
        $plan = @()
        if (-not $h.Healthy) {
            $chk = @{}; foreach ($ck in $h.Checks) { $chk[$ck.Name] = $ck.Ok }
            if (-not $chk['Internet'] -and $h.Tethering.State -eq 'NoUplink') { $plan += 'uplink down -> no repairs' }
            else {
                if (-not (Test-WRComponentOk $h 'AdGuard')) { $plan += "L1 restart $($C.AdGuardService)" }
                if (-not (Test-WRComponentOk $h 'Hotspot') -or -not (Test-WRComponentOk $h 'HotspotDns')) { $plan += 'L1 start ICS svcs/tethering, enforce uplink DNS, re-bind hotspot if uplink changed'; $plan += 'L2 restart ICS (if still bad, cooldown ok)'; $plan += 'L3 restart tethering (if still bad, cooldown ok)' }
            }
        }
        $upLoop = @($h.Checks | Where-Object Name -eq 'UplinkDnsLoopback')[0]
        if (-not $upLoop.Ok) { $plan += "NOTE uplink DNS not 127.0.0.1 ($($upLoop.Detail)) -> hotspot clients may bypass AdGuard (L1 fixes when admin, or run apply-admin.ps1)" }
        Write-Host ('Overall: ' + (Summ $h))
        if ($plan) { Write-Host 'Would do:'; $plan | ForEach-Object { Write-Host "  - $_" } } else { Write-Host 'Would do: nothing' }
        exit $(if ($h.Healthy) { 0 } else { 1 })
    }

    if ($h.Healthy) {
        if ([int]$st.FailCount -gt 0) { L "RECOVERED after $($st.FailCount) failing run(s)" 'OK' }
        $st.FailCount = 0
        Write-WRJson -Object $h -Path $C.StatusFile
        Write-WRJson -Object $st -Path $C.StateFile
        exit 0
    }

    $st.FailCount = [int]$st.FailCount + 1
    $chk = @{}; foreach ($ck in $h.Checks) { $chk[$ck.Name] = $ck.Ok }

    # uplink down: nothing to repair locally
    if (-not $chk['Internet'] -and $h.Tethering.State -eq 'NoUplink') {
        $last = if ($st.LastNag) { [datetime]$st.LastNag } else { [datetime]::MinValue }
        if (($now - $last).TotalMinutes -ge $C.Watchdog.NagEveryMinutes) { L 'uplink/internet down - skipping repairs' 'WARN'; $st.LastNag = $now.ToString('s') }
        Write-WRJson -Object $h -Path $C.StatusFile; Write-WRJson -Object $st -Path $C.StateFile; exit 1
    }

    if ($st.FailCount -gt $C.Watchdog.GiveUpAfterFails) {
        $last = if ($st.LastNag) { [datetime]$st.LastNag } else { [datetime]::MinValue }
        if (($now - $last).TotalMinutes -lt $C.Watchdog.NagEveryMinutes) { Write-WRJson -Object $h -Path $C.StatusFile; Write-WRJson -Object $st -Path $C.StateFile; exit 1 }
        L "still failing after $($st.FailCount) runs - needs manual attention (run status.ps1)" 'ERROR'; $st.LastNag = $now.ToString('s')
    }

    $bad = (@($h.Checks | Where-Object { -not $_.Ok -and $_.Severity -eq 'Critical' } | ForEach-Object { "$($_.Name)[$($_.Detail)]" })) -join ' | '
    L ("UNHEALTHY run#{0}: {1}" -f $st.FailCount, $bad) 'WARN'
    $hs = Join-Path $PSScriptRoot 'start-hotspot.ps1'

    # ---------------- L1 targeted
    if (-not (Test-WRComponentOk $h 'AdGuard')) {
        try {
            if ((Get-WRServiceState $C.AdGuardService) -eq 'Running') { Restart-Service $C.AdGuardService -Force -ErrorAction Stop } else { Start-Service $C.AdGuardService -ErrorAction Stop }
            L "L1 (re)started $($C.AdGuardService)" 'REPAIR'; Start-Sleep -Seconds 5
        } catch { L "L1 AdGuard restart failed: $($_.Exception.Message)" 'ERROR' }
    }
    foreach ($s in @($C.IcsServices) + @($C.DhcpService)) {
        if ((Get-WRServiceState $s) -eq 'Stopped') {
            try { Start-Service $s -ErrorAction Stop; L "L1 started $s" 'REPAIR' } catch { L "L1 start $s failed: $($_.Exception.Message)" 'ERROR' }
        }
    }
    if (-not $chk['UplinkDnsLoopback'] -and $C.EnforceLoopbackDns -and (Test-WRComponentOk (Get-WRHealth -Config $C) 'AdGuard')) {
        $fix = @(Get-WRNonLoopbackUplinks $C)
        if ($isAdmin) {
            foreach ($a in $fix) {
                try { Set-DnsClientServerAddress -InterfaceAlias $a -ServerAddresses $C.LoopbackDnsServers -ErrorAction Stop; L "L1 set $a DNS -> $($C.LoopbackDnsServers -join ',')" 'REPAIR' }
                catch { L "L1 DNS enforce on $a failed: $($_.Exception.Message)" 'ERROR' }
            }
            Clear-DnsClientCache
        } else { L "uplink DNS not 127.0.0.1 on $($fix -join ',') and not elevated - cannot fix (run apply-admin.ps1)" 'WARN' }
    }
    if ($h.Tethering.State -eq 'On' -and -not $chk['HotspotUplink']) {
        # failover: uplink changed since tethering started -> re-bind ICS to the new uplink
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $hs -Restart 2>&1 | Out-String
        L ('L1 uplink changed, start-hotspot -Restart: ' + (($out -replace '\s+', ' ').Trim())) 'REPAIR'
    } elseif ($h.Tethering.State -ne 'On') {
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $hs 2>&1 | Out-String
        L ('L1 start-hotspot: ' + (($out -replace '\s+', ' ').Trim())) 'REPAIR'
    }
    Start-Sleep -Seconds 5
    $h = Get-WRHealth -Config $C

    # A hotspot that resolves but does not block is an uplink DNS problem, not an ICS problem: restarts would not
    # fix it, so it only escalates when uplink DNS already points at 127.0.0.1 (i.e. ICS proxy is misbehaving).
    $hotspotBad = {
        param($x)
        $loopOk = @($x.Checks | Where-Object { $_.Name -eq 'UplinkDnsLoopback' -and $_.Ok }).Count -gt 0
        @($x.Checks | Where-Object { $_.Component -in 'Hotspot', 'HotspotDns' -and $_.Severity -eq 'Critical' -and -not $_.Ok -and ($loopOk -or $_.Name -ne 'DnsHotspot:block') }).Count -gt 0
    }
    $lastEsc = if ($st.LastEscalation) { [datetime]$st.LastEscalation } else { [datetime]::MinValue }
    $cool = (($now - $lastEsc).TotalMinutes -ge $C.Watchdog.CooldownMinutes)

    # ---------------- L2 ICS restart
    if ((& $hotspotBad $h) -and $cool) {
        foreach ($s in $C.IcsServices) {
            try { Set-Service $s -StartupType Automatic -ErrorAction SilentlyContinue; Restart-Service $s -Force -ErrorAction Stop; L "L2 restarted $s" 'REPAIR' }
            catch { L "L2 restart $s failed: $($_.Exception.Message)" 'ERROR' }
        }
        Start-Sleep -Seconds 4
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $hs 2>&1 | Out-String
        L ('L2 start-hotspot: ' + (($out -replace '\s+', ' ').Trim())) 'REPAIR'
        $st.LastEscalation = (Get-Date).ToString('s')
        Start-Sleep -Seconds 5
        $h = Get-WRHealth -Config $C

        # ---------------- L3 full hotspot restart (same run, only if L2 did not help)
        if (& $hotspotBad $h) {
            $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $hs -Restart 2>&1 | Out-String
            L ('L3 start-hotspot -Restart: ' + (($out -replace '\s+', ' ').Trim())) 'REPAIR'
            Start-Sleep -Seconds 5
            $h = Get-WRHealth -Config $C
        }
    } elseif (& $hotspotBad $h) {
        L "hotspot still unhealthy; L2/L3 in cooldown ($($C.Watchdog.CooldownMinutes) min)" 'WARN'
    }

    L ('after repairs: ' + (Summ $h)) $(if ($h.Healthy) { 'OK' } else { 'WARN' })
    if ($h.Healthy) { $st.FailCount = 0 }
    $st.LastRepair = (Get-Date).ToString('s')
    Write-WRJson -Object $h -Path $C.StatusFile
    Write-WRJson -Object $st -Path $C.StateFile
    exit $(if ($h.Healthy) { 0 } else { 1 })
} finally {
    # follow devices by MAC: re-point Kuma device monitors at their current WALLACE DHCP lease (cheap; no-op if unchanged)
    try { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'kuma-mac-sync.ps1') -Quiet | Out-Null } catch { }
    $mutex.ReleaseMutex(); $mutex.Dispose()
}
