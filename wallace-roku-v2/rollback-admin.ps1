<#
  rollback-admin.ps1 - undo apply-admin.ps1 using its backup folder. Run as administrator.
  Usage:
    rollback-admin.ps1                       # newest dev-config-backup\net-v2-* folder
    rollback-admin.ps1 -BackupDir <folder>   # a specific backup
    rollback-admin.ps1 -FullFirewallImport   # additionally re-import the complete firewall policy (.wfw)
  Restores: AdGuardHome.yaml, Wi-Fi DNS, firewall rules (removes 'Wallace-Roku v2' group, recreates the
  originals, un-scopes app rules), watchdog task (XML), Startup start-hotspot.cmd, DHCP inis/legacy scripts.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param([string]$BackupDir, [switch]$FullFirewallImport)
$ErrorActionPreference = 'Stop'
$V2 = $PSScriptRoot
. (Join-Path $V2 'lib.ps1')
$C = Get-WRConfig
$out = New-Object System.Collections.ArrayList; $script:Fail = 0
function Write-Res([string]$m, [string]$lvl = 'INFO') { $l = '{0} [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $lvl, $m; [void]$out.Add($l); Write-Host $l; if ($lvl -eq 'ERROR') { $script:Fail++ } }

if (-not (Test-WRAdmin) -and -not $WhatIfPreference) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$PSCommandPath`"")
    if ($BackupDir) { $a += @('-BackupDir', "`"$BackupDir`"") }; if ($FullFirewallImport) { $a += '-FullFirewallImport' }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $a; exit
}
if (-not $BackupDir) { $BackupDir = (Get-ChildItem $C.BackupRoot -Directory -Filter 'net-v2-*' | Sort-Object Name | Select-Object -Last 1).FullName }
if (-not $BackupDir -or -not (Test-Path (Join-Path $BackupDir 'manifest.json'))) { throw "no valid backup folder (manifest.json missing): $BackupDir" }
$M = Get-Content (Join-Path $BackupDir 'manifest.json') -Raw | ConvertFrom-Json
Write-Res "rolling back from $BackupDir"

# AdGuard yaml
if ($M.Yaml -and $PSCmdlet.ShouldProcess('AdGuardHome.yaml', 'restore')) {
    try {
        Stop-Service $C.AdGuardService -Force; for ($k = 0; $k -lt 30 -and (Get-WRServiceState $C.AdGuardService) -ne 'Stopped'; $k++) { Start-Sleep 1 }
        Copy-Item (Join-Path $BackupDir $M.Yaml) (Join-Path $C.AdGuardDir 'AdGuardHome.yaml') -Force
        Start-Service $C.AdGuardService; Start-Sleep 5
        $p = Test-WRDnsProbe -Server '127.0.0.1' -Config $C; Write-Res "yaml restored; AdGuard probe: $($p.Detail)" 'OK'
    } catch { Write-Res "yaml restore failed: $($_.Exception.Message)" 'ERROR' }
}
# Uplink DNS (uplink-aware: restores every adapter recorded in UplinkDns; older backups only have WifiDns)
$dnsList = if ($M.PSObject.Properties['UplinkDns'] -and @($M.UplinkDns).Count) { @($M.UplinkDns) } elseif ($M.WifiDns) { @($M.WifiDns) } else { @() }
foreach ($d in $dnsList) {
    if (-not $PSCmdlet.ShouldProcess($d.Alias, 'restore DNS')) { continue }
    try {
        $sv = @(); foreach ($s in @($d.StaticV4, $d.StaticV6)) { if ($s) { $sv += ($s -split '[, ]+' | Where-Object { $_ }) } }
        if ($sv.Count) { Set-DnsClientServerAddress -InterfaceAlias $d.Alias -ServerAddresses $sv; Write-Res "$($d.Alias) DNS -> static $($sv -join ',')" 'OK' }
        else { Set-DnsClientServerAddress -InterfaceAlias $d.Alias -ResetServerAddresses; Write-Res "$($d.Alias) DNS -> DHCP (router) as before" 'OK' }
        Clear-DnsClientCache
    } catch { Write-Res "DNS restore failed for $($d.Alias): $($_.Exception.Message)" 'ERROR' }
}
# Firewall
if ($PSCmdlet.ShouldProcess('Windows Firewall', 'restore rules')) {
    try {
        if ($FullFirewallImport) {
            & netsh advfirewall import (Join-Path $BackupDir 'firewall-full.wfw') | Out-Null; Write-Res 'full firewall policy re-imported' 'OK'
        } else {
            Get-NetFirewallRule -Group 'Wallace-Roku v2' -ErrorAction SilentlyContinue | Remove-NetFirewallRule; Write-Res "removed group 'Wallace-Roku v2' rules"
            foreach ($r in @($M.FirewallRules)) {
                Remove-NetFirewallRule -Name $r.Name -ErrorAction SilentlyContinue
                $p = @{ Name = $r.Name; DisplayName = $r.DisplayName; Direction = $r.Direction; Action = $r.Action; Profile = ($r.Profile -replace ' ', ''); Enabled = $r.Enabled; Protocol = $r.Protocol; RemoteAddress = @($r.RemoteAddress) }
                if (@($r.LocalPort) -and @($r.LocalPort)[0] -ne 'Any') { $p.LocalPort = @($r.LocalPort) }
                if ($r.Program -and $r.Program -ne 'Any') { $p.Program = $r.Program }
                if ($r.Description) { $p.Description = $r.Description }
                New-NetFirewallRule @p | Out-Null; Write-Res "recreated '$($r.DisplayName)'" 'OK'
            }
            foreach ($r in @($M.ScopedAppRules)) { Set-NetFirewallRule -Name $r.Name -RemoteAddress @($r.RemoteAddress); Write-Res "un-scoped '$($r.DisplayName)' -> $($r.RemoteAddress -join ',')" 'OK' }
        }
    } catch { Write-Res "firewall restore failed: $($_.Exception.Message) (try -FullFirewallImport)" 'ERROR' }
}
# Task
if ($M.Task -and $PSCmdlet.ShouldProcess($C.Watchdog.TaskName, 'restore task XML')) {
    try { $xml = Get-Content (Join-Path $BackupDir $M.Task) -Raw; Register-ScheduledTask -TaskName $C.Watchdog.TaskName -Xml $xml -Force | Out-Null; Write-Res 'watchdog task restored' 'OK' }
    catch { Write-Res "task restore failed: $($_.Exception.Message)" 'ERROR' }
}
# Startup
if ($M.Startup -and $PSCmdlet.ShouldProcess($C.StartupCmd, 'restore')) {
    try { Copy-Item (Join-Path $BackupDir $M.Startup) $C.StartupCmd -Force; Write-Res 'Startup start-hotspot.cmd restored' 'OK' } catch { Write-Res "startup restore failed: $($_.Exception.Message)" 'ERROR' }
}
# Files (.211 inis / scripts)
$dhcp = $false
foreach ($f in @($M.Files)) {
    if ($PSCmdlet.ShouldProcess($f.Original, 'restore')) {
        try { Copy-Item (Join-Path $BackupDir $f.Backup) $f.Original -Force; Write-Res "restored $($f.Original)" 'OK'; if ($f.Original -eq $C.DhcpIni) { $dhcp = $true } }
        catch { Write-Res "restore $($f.Original) failed: $($_.Exception.Message)" 'ERROR' }
    }
}
if ($dhcp) { try { Restart-Service $C.DhcpService -Force; Write-Res "restarted $($C.DhcpService)" } catch { Write-Res "restart $($C.DhcpService) failed: $($_.Exception.Message)" 'WARN' } }

Write-Res "rollback finished, errors=$script:Fail"
$out | Set-Content (Join-Path $V2 'rollback-result.txt') -Encoding UTF8 -WhatIf:$false
Add-Content (Join-Path $C.BackupRoot 'CHANGES.md') -Value @('', "## $(Get-Date -Format 'yyyy-MM-dd HH:mm') Wallace-Roku v2 ROLLBACK from $BackupDir (errors $script:Fail)") -Encoding UTF8 -WhatIf:$false

