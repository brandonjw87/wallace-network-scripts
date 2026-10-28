<#
  apply-admin.ps1 - ONE-TIME elevated migration to Wallace-Roku v2.  Run as administrator (UAC).
  Every change is backed up first to  dev-config-backup\net-v2-<timestamp>\  and can be undone with
  rollback-admin.ps1 (it picks the newest net-v2-* folder automatically).

  Steps (each is independent; a failure is recorded and the script moves on, except the backup step):
    0. Backup  : AdGuardHome.yaml, full firewall policy (.wfw) + JSON of every rule touched, the watchdog
                 task XML, the Startup start-hotspot.cmd, DHCP inis + legacy scripts with 192.0.2.31,
                 Wi-Fi DNS settings. Aborts if any backup fails.
    1. AdGuard : stop service, edit ONLY keys inside the dns: block (fallback_dns, bootstrap_dns,
                 ratelimit_whitelist, use_private_ptr_resolvers, local_ptr_upstreams). Filters, user rules,
                 users/password hash and everything outside dns: are verified byte-identical.
                 Validate with AdGuardHome.exe --check-config, start, DNS-probe; auto-restore on any failure.
    2. DNS     : Wi-Fi DNS -> 127.0.0.1, ::1, 192.0.2.15 (ICS proxies hotspot DNS to these, so this is
                 what makes Roku clients actually go through AdGuard). Only if step 1 left AdGuard healthy.
    3. .211    : replace 192.0.2.31 -> 192.0.2.28 in DHCP inis + legacy scripts; restart OpenDHCPServer.
    4. Firewall: replace AdGuard 53/3000 rules and PWA 8088 rule with all-profile rules scoped to
                 192.0.2.19/24,192.0.2.20/24,127.0.0.1; add scoped 11434/8080 port rules; scope the
                 existing ollama/python/node program rules to the same remote addresses.
    5. Task    : 'Wallace-Roku Watchdog' -> v2 watchdog.ps1, same principal/run level, every N minutes.
    6. Startup : start-hotspot.cmd -> v2 start-hotspot.ps1.
    7. Verify  : start hotspot if needed, run watchdog -CheckOnly, write apply-result.txt + CHANGES.md.
  Switches: -SkipYaml -SkipDns -SkipIpFix -SkipFirewall -SkipTask -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param([switch]$SkipYaml, [switch]$SkipDns, [switch]$SkipIpFix, [switch]$SkipFirewall, [switch]$SkipTask)

$ErrorActionPreference = 'Stop'
$V2 = $PSScriptRoot
. (Join-Path $V2 'lib.ps1')
$C = Get-WRConfig
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$Bk = Join-Path $C.BackupRoot "net-v2-$Stamp"
$ResultFile = Join-Path $V2 'apply-result.txt'
$Changes = Join-Path $C.BackupRoot 'CHANGES.md'
$Yaml = Join-Path $C.AdGuardDir 'AdGuardHome.yaml'
$Exe = Join-Path $C.AdGuardDir 'AdGuardHome.exe'
$Remote = @($C.TrustedRemoteAddresses)
$FwGroup = 'Wallace-Roku v2'
$script:Lines = New-Object System.Collections.ArrayList
$script:Fail = 0

function Write-Res([string]$m, [string]$lvl = 'INFO') {
    $l = '{0} [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $lvl, $m
    [void]$script:Lines.Add($l)
    $col = switch ($lvl) { 'ERROR' { 'Red' } 'WARN' { 'Yellow' } 'OK' { 'Green' } default { 'Gray' } }
    Write-Host $l -ForegroundColor $col
    if ($lvl -eq 'ERROR') { $script:Fail++ }
    Write-WRLog -Message $m -Level $(if ($lvl -in 'INFO','WARN','ERROR','OK') { $lvl } else { 'INFO' }) -Name 'apply-admin' -Config $C
}
function Save-Result {
    $hdr = @("Wallace-Roku v2 apply-admin result  $Stamp", "Backup folder: $Bk", "Errors: $script:Fail",
             "Undo everything: right-click PowerShell > Run as administrator, then:",
             "  powershell -ExecutionPolicy Bypass -File `"$V2\rollback-admin.ps1`" -BackupDir `"$Bk`"", '')
    ($hdr + $script:Lines) | Set-Content -LiteralPath $ResultFile -Encoding UTF8 -WhatIf:$false
}

if (-not (Test-WRAdmin) -and -not $WhatIfPreference) {
    Write-Host 'Not elevated. Re-launching via UAC...' -ForegroundColor Yellow
    Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$PSCommandPath`"")
    exit
}

# =====================================================================================  0. BACKUP
Write-Res "backup -> $Bk"
$manifest = [ordered]@{ Stamp = $Stamp; Files = @(); FirewallRules = @(); ScopedAppRules = @(); WifiDns = $null; Task = $null; Startup = $null; Yaml = $null }
try {
    if ($WhatIfPreference) { Write-Res 'WhatIf: skipping backup and all changes; showing plan only' 'WARN' }
    else {
        New-Item -ItemType Directory -Path $Bk, (Join-Path $Bk 'files') -Force | Out-Null
        # AdGuard yaml
        Copy-Item -LiteralPath $Yaml -Destination (Join-Path $Bk 'AdGuardHome.yaml.bak') -Force
        $manifest.Yaml = 'AdGuardHome.yaml.bak'
        # full firewall policy + JSON of rules we will touch
        $null = & netsh advfirewall export (Join-Path $Bk 'firewall-full.wfw')
        if (-not (Test-Path (Join-Path $Bk 'firewall-full.wfw'))) { throw 'firewall export failed' }
        $snap = {
            param($r)
            $pf = $r | Get-NetFirewallPortFilter; $af = $r | Get-NetFirewallAddressFilter; $ap = $r | Get-NetFirewallApplicationFilter
            [ordered]@{ Name = $r.Name; DisplayName = $r.DisplayName; Direction = [string]$r.Direction; Action = [string]$r.Action
                Profile = [string]$r.Profile; Enabled = [string]$r.Enabled; Protocol = [string]$pf.Protocol; LocalPort = @($pf.LocalPort)
                RemoteAddress = @($af.RemoteAddress); Program = [string]$ap.Program; Description = [string]$r.Description; Group = [string]$r.Group }
        }
        $replace = @(Get-NetFirewallRule | Where-Object { $_.DisplayName -like 'AdGuardHome *' -or $_.DisplayName -eq 'Local AI PWA 8088' })
        $manifest.FirewallRules = @($replace | ForEach-Object { & $snap $_ })
        $appRules = @(Get-NetFirewallApplicationFilter | Where-Object { $_.Program -match '\\(ollama|python|node)\.exe$' } |
            Get-NetFirewallRule | Where-Object { $_.Direction -eq 'Inbound' -and $_.Action -eq 'Allow' })
        $manifest.ScopedAppRules = @($appRules | ForEach-Object { & $snap $_ })
        # scheduled task + startup
        $t = Get-ScheduledTask -TaskName $C.Watchdog.TaskName -ErrorAction SilentlyContinue
        if ($t) { Export-ScheduledTask -TaskName $C.Watchdog.TaskName | Set-Content (Join-Path $Bk 'watchdog-task.xml') -Encoding Unicode; $manifest.Task = 'watchdog-task.xml' }
        if (Test-Path -LiteralPath $C.StartupCmd) { Copy-Item -LiteralPath $C.StartupCmd (Join-Path $Bk 'start-hotspot.cmd'); $manifest.Startup = 'start-hotspot.cmd' }
        # files containing the stale LAN IP
        $ipFiles = @($C.DhcpIni) + @('dhcpsrv.ini', 'roku-adblock.ps1', '3-healthcheck.ps1', '1-set-static-ip.ps1', 'hotspot-upgrade.ps1' | ForEach-Object { Join-Path $C.LegacyDir $_ })
        $i = 0
        foreach ($f in $ipFiles) {
            if (Test-Path -LiteralPath $f) { $i++; $dst = "files\$i-" + (Split-Path $f -Leaf); Copy-Item -LiteralPath $f (Join-Path $Bk $dst); $manifest.Files += [ordered]@{ Original = $f; Backup = $dst } }
        }
        # Wi-Fi DNS (empty registry NameServer = came from DHCP)
        $ad = Get-NetAdapter -Name $C.WifiAlias -ErrorAction Stop
        $g = $ad.InterfaceGuid
$v4 = try { [string](Get-ItemPropertyValue "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$g" -Name NameServer -ErrorAction Stop) } catch { "" }
$v6 = try { [string](Get-ItemPropertyValue "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters\Interfaces\$g" -Name NameServer -ErrorAction Stop) } catch { "" }
        $manifest.WifiDns = [ordered]@{ Alias = $C.WifiAlias; StaticV4 = [string]$v4; StaticV6 = [string]$v6
            Effective = @((Get-DnsClientServerAddress -InterfaceAlias $C.WifiAlias).ServerAddresses) }
        # Uplink-aware: also snapshot DNS of every uplink adapter (Ethernet + Wi-Fi) so rollback can restore all of them
        $manifest.UplinkDns = @(); foreach ($ua in (Get-WRUplinkAliases $C)) { $uad = Get-NetAdapter -Name $ua -ErrorAction SilentlyContinue; if (-not $uad) { continue }; $ug = $uad.InterfaceGuid
            $u4 = try { [string](Get-ItemPropertyValue "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$ug" -Name NameServer -ErrorAction Stop) } catch { "" }
            $u6 = try { [string](Get-ItemPropertyValue "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters\Interfaces\$ug" -Name NameServer -ErrorAction Stop) } catch { "" }
            $manifest.UplinkDns += [ordered]@{ Alias = $ua; StaticV4 = $u4; StaticV6 = $u6; Effective = @((Get-DnsClientServerAddress -InterfaceAlias $ua -ErrorAction SilentlyContinue).ServerAddresses) } }
        $manifest | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $Bk 'manifest.json') -Encoding UTF8
        foreach ($need in 'AdGuardHome.yaml.bak', 'firewall-full.wfw', 'manifest.json') { if (-not (Test-Path (Join-Path $Bk $need))) { throw "backup missing $need" } }
        if ((Get-Item (Join-Path $Bk 'AdGuardHome.yaml.bak')).Length -ne (Get-Item $Yaml).Length) { throw 'yaml backup size mismatch' }
        Write-Res "backup complete: yaml, firewall-full.wfw, $(@($manifest.FirewallRules).Count)+$(@($manifest.ScopedAppRules).Count) rule snapshots, task, startup, $(@($manifest.Files).Count) files, Wi-Fi DNS" 'OK'
    }
} catch { Write-Res "BACKUP FAILED - aborting with no changes: $($_.Exception.Message)" 'ERROR'; Save-Result; exit 1 }

# =====================================================================================  YAML helpers
function Get-DnsBlock([string[]]$L) {
    $s = -1; for ($i = 0; $i -lt $L.Count; $i++) { if ($L[$i] -match '^dns:\s*$') { $s = $i; break } }
    if ($s -lt 0) { throw 'dns: block not found' }
    $e = $L.Count; for ($i = $s + 1; $i -lt $L.Count; $i++) { if ($L[$i] -match '^\S') { $e = $i; break } }
    return @($s, $e)
}
function Find-Key([string[]]$L, [string]$Key) {
    $b = Get-DnsBlock $L
    for ($i = $b[0] + 1; $i -lt $b[1]; $i++) { if ($L[$i] -match "^  $([regex]::Escape($Key)):") { return $i } }
    throw "dns.$Key not found"
}
function Get-YamlList([string[]]$L, [string]$Key) {
    $i = Find-Key $L $Key
    if ($L[$i] -match ':\s*\[\]\s*$') { return @() }
    $out = @(); $j = $i + 1
    while ($j -lt $L.Count -and $L[$j] -match '^    - (.*)$') { $out += $Matches[1].Trim().Trim("'").Trim('"'); $j++ }
    return $out
}
function Set-YamlList([string[]]$L, [string]$Key, [string[]]$Values) {
    $i = Find-Key $L $Key
    $j = $i + 1; while ($j -lt $L.Count -and $L[$j] -match '^    - ') { $j++ }
    $new = if (@($Values).Count) { @("  ${Key}:") + @($Values | ForEach-Object { "    - $_" }) } else { @("  ${Key}: []") }
    $before = if ($i -gt 0) { $L[0..($i - 1)] } else { @() }
    $after = if ($j -lt $L.Count) { $L[$j..($L.Count - 1)] } else { @() }
    return [string[]](@($before) + $new + @($after))
}
function Set-YamlScalar([string[]]$L, [string]$Key, [string]$Value) {
    $i = Find-Key $L $Key; $L = [string[]]$L.Clone(); $L[$i] = "  ${Key}: $Value"; return $L
}
function Merge([string[]]$a, [string[]]$b) { $o = New-Object System.Collections.ArrayList; foreach ($x in @($a) + @($b)) { if ($x -and -not $o.Contains($x)) { [void]$o.Add($x) } }; return [string[]]$o }

function Wait-Svc([string]$Name, [string]$Want, [int]$Sec = 30) {
    for ($k = 0; $k -lt $Sec; $k++) { if ((Get-WRServiceState $Name) -eq $Want) { return $true }; Start-Sleep 1 }; return $false
}
function Test-AghDns { for ($k = 0; $k -lt 10; $k++) { $p = Test-WRDnsProbe -Server '127.0.0.1' -Config $C; if ($p.Resolves -and $p.Blocks) { return $p }; Start-Sleep 3 }; return $p }
function Restore-Yaml([string]$why) {
    Write-Res "RESTORING AdGuardHome.yaml from backup ($why)" 'WARN'
    try { Stop-Service $C.AdGuardService -Force -ErrorAction SilentlyContinue; [void](Wait-Svc $C.AdGuardService 'Stopped' 20)
        Copy-Item (Join-Path $Bk 'AdGuardHome.yaml.bak') $Yaml -Force; Start-Service $C.AdGuardService; [void](Wait-Svc $C.AdGuardService 'Running' 30)
        $p = Test-AghDns; Write-Res "restored; AdGuard probe: resolves=$($p.Resolves) blocks=$($p.Blocks)" $(if ($p.Resolves) { 'OK' } else { 'ERROR' })
    } catch { Write-Res "restore failed: $($_.Exception.Message) - run rollback-admin.ps1" 'ERROR' }
}

# =====================================================================================  1. ADGUARD YAML
$aghOk = $true
if ($SkipYaml) { Write-Res 'step 1 (yaml) skipped' 'WARN' }
elseif ($PSCmdlet.ShouldProcess($Yaml, 'edit dns block (fallback/bootstrap/ratelimit_whitelist/private PTR), validate, restart')) {
    try {
        $help = (& $Exe --help 2>&1 | Out-String)
        $hasCheck = $help -match '--check-config'
        Write-Res "AdGuardHome.exe --check-config supported: $hasCheck"
        Stop-Service $C.AdGuardService -Force
        if (-not (Wait-Svc $C.AdGuardService 'Stopped' 30)) { throw 'service did not stop' }
        $raw = [IO.File]::ReadAllText($Yaml)
        $nl = if ($raw -match "`r`n") { "`r`n" } else { "`n" }
        $L0 = [string[]]($raw -split "`r?`n")
        $L = $L0
        $boot = Merge (Get-YamlList $L 'bootstrap_dns') @('1.1.1.1', '9.9.9.9', '1.0.0.1', '149.112.112.112')
        $L = Set-YamlList $L 'bootstrap_dns' $boot
        $fb = Merge (Get-YamlList $L 'fallback_dns') @('tls://dns.quad9.net', 'tls://1dot1dot1dot1.cloudflare-dns.com')
        $L = Set-YamlList $L 'fallback_dns' $fb
        # ratelimit_whitelist takes single IPs only (no CIDR, per AdGuard source). Hotspot clients reach AdGuard
        # through the ICS proxy as 127.0.0.1, so whitelisting the local addresses covers 192.0.2.19/24.
        $rokuIps = @()
        $mf = Join-Path $C.LegacyDir 'roku-macs.txt'
        if (Test-Path $mf) { $rokuIps = @(Get-Content $mf | Where-Object { $_ -notmatch '^\s*#' } | ForEach-Object { ($_ -split ',')[1] } | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' }) }
        $wl = Merge (Get-YamlList $L 'ratelimit_whitelist') (@('127.0.0.1', '::1', $C.HotspotIp, $C.LanIp) + $rokuIps)
        $L = Set-YamlList $L 'ratelimit_whitelist' $wl
        $L = Set-YamlScalar $L 'use_private_ptr_resolvers' 'true'
        $L = Set-YamlList $L 'local_ptr_upstreams' (Merge (Get-YamlList $L 'local_ptr_upstreams') @($C.RouterIp))
        # integrity: everything outside dns: must be byte-identical (filters, user_rules, users + password hash ...)
        $b0 = Get-DnsBlock $L0; $b1 = Get-DnsBlock $L
        $pre0 = $L0[0..$b0[0]] -join "`n"; $pre1 = $L[0..$b1[0]] -join "`n"
        $post0 = if ($b0[1] -lt $L0.Count) { $L0[$b0[1]..($L0.Count - 1)] -join "`n" } else { '' }
        $post1 = if ($b1[1] -lt $L.Count) { $L[$b1[1]..($L.Count - 1)] -join "`n" } else { '' }
        if ($pre0 -ne $pre1 -or $post0 -ne $post1) { throw 'integrity check failed: content outside dns: changed' }
        $f0 = @($L0 | Where-Object { $_ -match '^\s+url: ' }).Count; $f1 = @($L | Where-Object { $_ -match '^\s+url: ' }).Count
        if ($f0 -ne $f1) { throw "filter count changed $f0 -> $f1" }
        [IO.File]::WriteAllText($Yaml, ($L -join $nl), (New-Object Text.UTF8Encoding($false)))
        Write-Res "yaml edited: bootstrap=$($boot -join ',') | fallback=$($fb -join ',') | ratelimit_whitelist=$($wl -join ',') | private PTR -> $($C.RouterIp); filters kept: $f1"
        if ($hasCheck) {
            $out = (cmd /c "`"$Exe`" --check-config -c `"$Yaml`" -w `"$($C.AdGuardDir)`" --no-check-update 2>&1" | Out-String)
            $code = $LASTEXITCODE
            $safe = ($out -split "`r?`n" | Where-Object { $_ -and $_ -notmatch '(?i)password|private_key|secret' } | Select-Object -Last 5) -join ' / '
            Write-Res "check-config exit=$code $safe"
            if ($code -ne 0) { throw "check-config failed (exit $code)" }
        }
        Start-Service $C.AdGuardService
        if (-not (Wait-Svc $C.AdGuardService 'Running' 30)) { throw 'service did not start' }
        $p = Test-AghDns
        if (-not ($p.Resolves -and $p.Blocks)) { throw "DNS probe failed: $($p.Detail)" }
        Write-Res "AdGuard running with new config; probe: $($p.Detail)" 'OK'
    } catch {
        Write-Res "step 1 failed: $($_.Exception.Message)" 'ERROR'
        Restore-Yaml $_.Exception.Message
        $aghOk = (Test-WRDnsProbe -Server '127.0.0.1' -Config $C).Resolves
    }
}

# =====================================================================================  2. WI-FI DNS -> AdGuard
if ($SkipDns) { Write-Res 'step 2 (Wi-Fi DNS) skipped' 'WARN' }
elseif (-not $aghOk) { Write-Res 'step 2 skipped: AdGuard not healthy, leaving Wi-Fi DNS on router' 'WARN' }
elseif ($PSCmdlet.ShouldProcess($C.WifiAlias, "DNS -> $($C.LoopbackDnsServers -join ',')")) {
    try {
        $dnsDone = @(); foreach ($ua in (Get-WRUplinkAliases $C)) { if (Get-NetAdapter -Name $ua -ErrorAction SilentlyContinue) { Set-DnsClientServerAddress -InterfaceAlias $ua -ServerAddresses $C.LoopbackDnsServers; $dnsDone += $ua } }
        Clear-DnsClientCache
        Write-Res "uplink DNS set to $($C.LoopbackDnsServers -join ',') on $($dnsDone -join ',') (Wi-Fi was: $($manifest.WifiDns.Effective -join ','))" 'OK'
        Start-Sleep 3
        $ph = Test-WRDnsProbe -Server $C.HotspotIp -Config $C
        if (-not $ph.Blocks) {
            Write-Res "hotspot DNS ($($C.HotspotIp)) not blocking yet ($($ph.Detail)) - restarting ICS so its DNS proxy picks up the change" 'WARN'
            foreach ($s in $C.IcsServices) { Restart-Service $s -Force -ErrorAction SilentlyContinue }
            Start-Sleep 4
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $V2 'start-hotspot.ps1') | Out-Null
            Start-Sleep 5
            $ph = Test-WRDnsProbe -Server $C.HotspotIp -Config $C
        }
        Write-Res "hotspot DNS probe: resolves=$($ph.Resolves) blocks=$($ph.Blocks) ($($ph.Detail))" $(if ($ph.Resolves -and $ph.Blocks) { 'OK' } else { 'WARN' })
    } catch { Write-Res "step 2 failed: $($_.Exception.Message)" 'ERROR' }
}

# =====================================================================================  3. STALE .211 -> .210
if ($SkipIpFix) { Write-Res 'step 3 (.211 fix) skipped' 'WARN' }
elseif (-not $WhatIfPreference) {
    $dhcpChanged = $false
    foreach ($f in $manifest.Files) {
        try {
            $txt = [IO.File]::ReadAllText($f.Original)
            if ($txt.Contains($C.StaleLanIp)) {
                $n = ([regex]::Matches($txt, [regex]::Escape($C.StaleLanIp))).Count
                [IO.File]::WriteAllText($f.Original, $txt.Replace($C.StaleLanIp, $C.LanIp), (New-Object Text.UTF8Encoding($false)))
                Write-Res "$($f.Original): $n x $($C.StaleLanIp) -> $($C.LanIp)" 'OK'
                if ($f.Original -eq $C.DhcpIni) { $dhcpChanged = $true }
            }
        } catch { Write-Res "ip fix failed for $($f.Original): $($_.Exception.Message)" 'ERROR' }
    }
    if ($dhcpChanged) {
        try { Restart-Service $C.DhcpService -Force; Write-Res "restarted $($C.DhcpService)" 'OK' } catch { Write-Res "restart $($C.DhcpService) failed: $($_.Exception.Message)" 'ERROR' }
        $dhcp = (Get-NetIPInterface -InterfaceAlias $C.WifiAlias -AddressFamily IPv4).Dhcp
        if ([string]$dhcp -eq 'Enabled') { Write-Res "NOTE: Wi-Fi gets $($C.LanIp) by DHCP reservation; Open DHCP Server only binds to STATIC interfaces, so it will keep logging 'No Static Interface ready' (main-LAN Roku DHCP stays inactive; hotspot unaffected)" 'WARN' }
    }
} else { Write-Res 'WhatIf: would replace .211 -> .210 in DHCP inis and legacy scripts' }

# =====================================================================================  4. FIREWALL
if ($SkipFirewall) { Write-Res 'step 4 (firewall) skipped' 'WARN' }
elseif ($PSCmdlet.ShouldProcess('Windows Firewall', 'replace AdGuard/PWA rules with scoped all-profile rules; scope app rules')) {
    try {
        foreach ($r in $manifest.FirewallRules) { Remove-NetFirewallRule -Name $r.Name -ErrorAction SilentlyContinue; Write-Res "removed rule '$($r.DisplayName)' ($($r.Profile), remote $($r.RemoteAddress -join ','))" }
        Get-NetFirewallRule -Group $FwGroup -ErrorAction SilentlyContinue | Remove-NetFirewallRule
        $new = @(
            @{ D = 'WR2 AdGuard DNS UDP 53'; P = 'UDP'; Port = $C.Ports.Dns },
            @{ D = 'WR2 AdGuard DNS TCP 53'; P = 'TCP'; Port = $C.Ports.Dns },
            @{ D = 'WR2 AdGuard Web 3000'; P = 'TCP'; Port = $C.Ports.AdGuardWeb }
            # (Open WebUI 8080 / Local AI PWA 8088 rules removed 2026-10-27: local AI uninstalled)
        )
        foreach ($n in $new) {
            New-NetFirewallRule -DisplayName $n.D -Group $FwGroup -Direction Inbound -Action Allow -Protocol $n.P -LocalPort $n.Port `
                -Profile Any -RemoteAddress $Remote -Description 'Wallace-Roku v2 (apply-admin.ps1); scoped to hotspot+LAN+loopback' | Out-Null
            Write-Res "added '$($n.D)' $($n.P)/$($n.Port) all profiles, remote $($Remote -join ',')" 'OK'
        }
        foreach ($r in $manifest.ScopedAppRules) {
            if ((Get-NetFirewallRule -Name $r.Name).EdgeTraversalPolicy -eq 'DeferToUser') { Set-NetFirewallRule -Name $r.Name -EdgeTraversalPolicy Block }; Set-NetFirewallRule -Name $r.Name -RemoteAddress $Remote
            Write-Res "scoped '$($r.DisplayName)' $($r.Protocol) [$($r.Profile)] remote Any -> $($Remote -join ',')" 'OK'
        }
        foreach ($port in $C.Ports.AdGuardWeb) {
            Write-Res "post-firewall local check 127.0.0.1:$port listening=$(Test-WRTcp '127.0.0.1' $port 1500)"
        }
    } catch { Write-Res "step 4 failed: $($_.Exception.Message)" 'ERROR' }
}

# =====================================================================================  5. TASK + 6. STARTUP
if ($SkipTask) { Write-Res 'steps 5/6 (task/startup) skipped' 'WARN' }
elseif ($PSCmdlet.ShouldProcess($C.Watchdog.TaskName, 'point at v2 watchdog; update Startup cmd')) {
    try {
        $t = Get-ScheduledTask -TaskName $C.Watchdog.TaskName -ErrorAction Stop
        $t.Actions = @(New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ("-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"{0}`"" -f (Join-Path $V2 'watchdog.ps1')))
        foreach ($tr in $t.Triggers) { if ($tr.Repetition -and $tr.Repetition.Interval) { $tr.Repetition.Interval = "PT$($C.Watchdog.IntervalMinutes)M" } }
        if ($t.Settings) { $t.Settings.MultipleInstances = 'IgnoreNew'; $t.Settings.ExecutionTimeLimit = 'PT10M' }
        Set-ScheduledTask -InputObject $t | Out-Null
        $t2 = Get-ScheduledTask -TaskName $C.Watchdog.TaskName
        Write-Res "task '$($C.Watchdog.TaskName)' -> v2 watchdog every $($C.Watchdog.IntervalMinutes) min; principal $($t2.Principal.UserId)/$($t2.Principal.RunLevel)/$($t2.Principal.LogonType)" 'OK'
    } catch { Write-Res "step 5 failed: $($_.Exception.Message)" 'ERROR' }
    try {
        $line = '@start "" /min powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $V2 'start-hotspot.ps1')
        Set-Content -LiteralPath $C.StartupCmd -Value $line -Encoding ASCII
        Write-Res "Startup start-hotspot.cmd -> v2" 'OK'
    } catch { Write-Res "step 6 failed: $($_.Exception.Message)" 'ERROR' }
}

# =====================================================================================  7. VERIFY + LOG
if (-not $WhatIfPreference) {
    $ti = Get-WRTetheringInfo
    if ($ti.State -ne 'On') { Write-Res "hotspot state $($ti.State) - running v2 start-hotspot"; & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $V2 'start-hotspot.ps1') | Out-Null }
    $chkOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $V2 'watchdog.ps1') -CheckOnly 2>&1 | Out-String
    $chkOut -split "`r?`n" | Where-Object { $_.Trim() } | ForEach-Object { [void]$script:Lines.Add("    $_") }
    $md = @('', "## $(Get-Date -Format 'yyyy-MM-dd HH:mm') Wallace-Roku v2 apply-admin (backup $Bk)",
        "- AdGuardHome.yaml dns: bootstrap +1.0.0.1/149.112.112.112, fallback_dns tls Quad9+Cloudflare, ratelimit_whitelist local IPs, private PTR -> $($C.RouterIp). Filters/users untouched.",
        "- Wi-Fi DNS -> $($C.LoopbackDnsServers -join ',') so ICS forwards hotspot DNS to AdGuard (was router-only).",
        "- $($C.StaleLanIp) -> $($C.LanIp) in DHCP inis and legacy roku-dhcp scripts.",
        "- Firewall: AdGuard 53/3000 + PWA 8088 rules replaced by group '$FwGroup' (all profiles, remote $($Remote -join ',')); added 11434/8080; ollama/python/node rules scoped.",
        "- Task '$($C.Watchdog.TaskName)' -> $V2\watchdog.ps1 every $($C.Watchdog.IntervalMinutes) min; Startup start-hotspot.cmd -> v2.",
        "- Errors: $script:Fail. Result: $ResultFile",
        "- Undo (admin): powershell -ExecutionPolicy Bypass -File `"$V2\rollback-admin.ps1`" -BackupDir `"$Bk`"")
    Add-Content -LiteralPath $Changes -Value $md -Encoding UTF8
}
Write-Res "done. errors=$script:Fail  result file: $ResultFile" $(if ($script:Fail) { 'WARN' } else { 'OK' })
Save-Result


