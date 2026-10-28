<#
  status.ps1 - one-screen dashboard for the WALLACE hotspot (v2 engine). Read-only, no admin, prints no secrets.
  Usage: .\status.ps1   [-Log 8]   (number of recent watchdog log lines to show)
#>
param([int]$Log = 8)
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib.ps1')
$C = Get-WRConfig
$h = Get-WRHealth -Config $C -IncludeApps

function Row($label, $ok, $text, [string]$sev = 'Critical') {
    $tag = if ($ok) { '[ OK ]' } elseif ($sev -eq 'Critical') { '[FAIL]' } elseif ($sev -eq 'Warn') { '[WARN]' } else { '[ -- ]' }
    $col = if ($ok) { 'Green' } elseif ($sev -eq 'Critical') { 'Red' } elseif ($sev -eq 'Warn') { 'Yellow' } else { 'DarkGray' }
    Write-Host ('{0} ' -f $tag) -ForegroundColor $col -NoNewline
    Write-Host ('{0,-20} {1}' -f $label, $text)
}

Write-Host ('=' * 78)
Write-Host (' WALLACE hotspot status   {0}   overall: {1}' -f $h.Time, $(if ($h.Healthy) { 'HEALTHY' } else { 'PROBLEM: ' + ($h.FailedCritical -join ', ') })) -ForegroundColor $(if ($h.Healthy) { 'Green' } else { 'Red' })
Write-Host ('=' * 78)
foreach ($grp in ($h.Checks | Group-Object Component)) {
    Write-Host (" {0}" -f $grp.Name) -ForegroundColor Cyan
    foreach ($ck in $grp.Group) { Row $ck.Name $ck.Ok $ck.Detail $ck.Severity }
}

$t = $h.Tethering
if (@($t.Clients).Count) {
    Write-Host ' Hotspot clients' -ForegroundColor Cyan
    foreach ($cl in $t.Clients) { Write-Host ('   {0}  {1}' -f $cl.Mac, $cl.Names) }
}
$macFile = Join-Path $C.LegacyDir 'roku-macs.txt'
if (Test-Path $macFile) {
    $known = @(Get-Content $macFile | Where-Object { $_ -and $_ -notmatch '^\s*#' } | ForEach-Object { ($_ -split ',')[0].Trim().ToLower() })
    $seen = @($t.Clients | ForEach-Object { $_.Mac.ToLower() -replace '-', ':' })
    $hit = @($known | Where-Object { $seen -contains $_ }).Count
    Write-Host (' Known Roku MACs on hotspot: {0} of {1}' -f $hit, $known.Count)
}

Write-Host ' Uplink' -ForegroundColor Cyan
$au = Get-WRActiveUplink $C
Write-Host ('   Active uplink: ' + $(if ($au) { "$($au.Alias) ($($au.LinkSpeed), gw $($au.Gateway), metric $($au.Metric))" } else { 'none' }))
netsh wlan show interfaces | Select-String '^\s+(SSID|Channel|Signal|Receive rate|Radio type)\s' | ForEach-Object { Write-Host ('   ' + $_.Line.Trim()) }
$prof = Get-NetConnectionProfile -ErrorAction SilentlyContinue | ForEach-Object { "$($_.InterfaceAlias)=$($_.NetworkCategory)" }
Write-Host ('   Profiles: ' + ($prof -join '  '))

$stf = $C.StatusFile
if (Test-Path $stf) { $age = [int]((Get-Date) - (Get-Item $stf).LastWriteTime).TotalMinutes; Write-Host (" Watchdog status.json age: {0} min" -f $age) }
$wl = Join-Path $C.LogDir 'watchdog.log'
if (Test-Path $wl) {
    Write-Host " Last watchdog log lines" -ForegroundColor Cyan
    Get-Content $wl -Tail $Log | ForEach-Object { Write-Host "   $_" }
} else { Write-Host ' (no v2 watchdog log yet - quiet when healthy, or task still points at legacy script)' }
Write-Host ('=' * 78)
