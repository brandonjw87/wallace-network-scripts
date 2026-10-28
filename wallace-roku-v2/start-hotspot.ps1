<#
  start-hotspot.ps1 (v2) - bring up the 'WALLACE' Mobile Hotspot idempotently.
  Usage:
    .\start-hotspot.ps1               # start if off (no-op if already On and configured)
    .\start-hotspot.ps1 -Restart      # stop + start tethering (watchdog level 3)
    .\start-hotspot.ps1 -Reconfigure  # force re-apply SSID/passphrase/band (kicks clients)
    .\start-hotspot.ps1 -WhatIf       # report what would happen, change nothing
  Behaviour:
    * binds to the ACTIVE uplink (lowest-metric adapter with a gateway: Ethernet or Wi-Fi) and records it in
      logs\hotspot-uplink.json so the watchdog can re-bind (-Restart) if the uplink fails over
    * waits/backs off for the uplink profile (Wi-Fi can be late at logon)
    * applies SSID + passphrase (read from PassphraseFile, never printed) + band only when they differ
    * prefers 5 GHz; falls back to Auto band if a 5 GHz start fails
    * disables the "turn off when no devices are connected" timeout
    * retries with exponential backoff; exit code 0 = On, 1 = failed
  No admin needed (runs as Brandon). Windows PowerShell 5.1 only.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param([switch]$Restart, [switch]$Reconfigure, [int]$MaxAttempts = 4)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')
$C = Get-WRConfig
function L([string]$m, [string]$lvl = 'INFO') { Write-WRLog -Message $m -Level $lvl -Name 'start-hotspot' -Config $C -Echo }

try { Initialize-WRWinRT } catch { L "WinRT init failed: $($_.Exception.Message)" 'ERROR'; exit 1 }
$TM = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]
$Band = [Windows.Networking.NetworkOperators.TetheringWiFiBand]
$OpResult = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult]

# 1) uplink-bound manager, with backoff
$mgr = $null
for ($i = 1; $i -le $MaxAttempts -and -not $mgr; $i++) {
    $mgr = Get-WRTetheringManager -Config $C
    if (-not $mgr) { $w = [math]::Pow(2, $i); L "no uplink profile yet (attempt $i/$MaxAttempts), waiting ${w}s" 'WARN'; Start-Sleep -Seconds $w }
}
if (-not $mgr) { L 'giving up: no internet connection profile to share' 'ERROR'; exit 1 }
$wasOn = ([string]$mgr.TetheringOperationalState -eq 'On')
L "uplink: $(if ($script:WRBoundUplink) { $script:WRBoundUplink } else { 'Windows internet profile' })"

# 2) never auto-off when idle (Roku sleeps -> 0 clients -> Windows would stop the hotspot)
if ($PSCmdlet.ShouldProcess('tethering', 'DisableNoConnectionsTimeout')) {
    try { [void]$TM::DisableNoConnectionsTimeout() } catch {
        try { Wait-WRAsyncAction ($TM::DisableNoConnectionsTimeoutAsync()) 15 } catch { L "could not disable idle timeout: $($_.Exception.Message)" 'WARN' }
    }
}

function Set-HotspotConfig([string]$WantBand) {
    $ap = $mgr.GetCurrentAccessPointConfiguration()
    $pw = $null
    if (Test-Path -LiteralPath $C.PassphraseFile) { $pw = (Get-Content -LiteralPath $C.PassphraseFile -Raw).Trim() }
    if (-not $pw -or $pw.Length -lt 8) { L "passphrase file missing or <8 chars: $($C.PassphraseFile)" 'ERROR'; return $false }
    $bandOk = $true
    try {
        $supported = $ap.IsBandSupported($Band::$WantBand)
        if (-not $supported -and $WantBand -ne 'Auto') { L "band $WantBand not supported by adapter, using Auto" 'WARN'; $WantBand = 'Auto' }
        $bandOk = ([string]$ap.Band -eq $WantBand)
    } catch { $bandOk = $true }  # older builds without Band support
    $need = $Reconfigure -or ($ap.Ssid -ne $C.Ssid) -or ($ap.Passphrase -ne $pw) -or (-not $bandOk)
    if (-not $need) { $pw = $null; return $true }
    if (-not $PSCmdlet.ShouldProcess("SSID $($C.Ssid) band $WantBand", 'ConfigureAccessPoint')) { $pw = $null; return $true }
    $ap.Ssid = $C.Ssid
    $ap.Passphrase = $pw
    try { $ap.Band = $Band::$WantBand } catch { }
    $pw = $null
    Wait-WRAsyncAction ($mgr.ConfigureAccessPointAsync($ap)) 30
    L "applied AP config: SSID=$($C.Ssid) band=$WantBand (passphrase from file, not logged)"
    return $true
}

function Wait-State([string]$Want, [int]$Sec = 15) {
    for ($k = 0; $k -lt $Sec; $k++) { if ([string]$mgr.TetheringOperationalState -eq $Want) { return $true }; Start-Sleep -Seconds 1 }
    return ([string]$mgr.TetheringOperationalState -eq $Want)
}

$wantBand = [string]$C.PreferredBand
try { if (-not (Set-HotspotConfig $wantBand)) { exit 1 } } catch { L "configure failed: $($_.Exception.Message)" 'ERROR' }

# 3) optional restart
if ($Restart -and [string]$mgr.TetheringOperationalState -eq 'On') {
    if ($PSCmdlet.ShouldProcess('tethering', 'Stop (restart)')) {
        try { $r = Wait-WRAsyncOp ($mgr.StopTetheringAsync()) $OpResult 30; L "stop: $($r.Status)"; [void](Wait-State 'Off' 10) } catch { L "stop failed: $($_.Exception.Message)" 'WARN' }
    }
}

# 4) start with retries/backoff and 5GHz -> Auto fallback
if ([string]$mgr.TetheringOperationalState -eq 'On') {
    L "already On (SSID $($C.Ssid)) - nothing to do"
} elseif (-not $PSCmdlet.ShouldProcess('tethering', 'Start')) {
    L "WhatIf: would start tethering (current state $($mgr.TetheringOperationalState))"
} else {
    for ($a = 1; $a -le $MaxAttempts; $a++) {
        try {
            $r = Wait-WRAsyncOp ($mgr.StartTetheringAsync()) $OpResult 45
            $msg = [string]$r.AdditionalErrorMessage
            L ("start attempt ${a}: $($r.Status) $msg".Trim())
            if ([string]$r.Status -eq 'Success' -and (Wait-State 'On' 15)) { break }
        } catch { L "start attempt $a threw: $($_.Exception.Message)" 'WARN' }
        if ($a -ge 2 -and $wantBand -ne 'Auto') {
            $wantBand = 'Auto'; L 'falling back to Auto band' 'WARN'
            try { [void](Set-HotspotConfig 'Auto') } catch { L "band fallback failed: $($_.Exception.Message)" 'WARN' }
        }
        $w = [math]::Pow(2, $a); Start-Sleep -Seconds $w
        $m2 = Get-WRTetheringManager -Config $C; if ($m2) { $mgr = $m2 }
    }
}

$info = Get-WRTetheringInfo -Config $C
# record which uplink ICS is sharing (only when we (re)started it, or when nothing is recorded yet)
$upFile = Get-WRHotspotUplinkFile $C
if ($info.State -eq 'On' -and -not $WhatIfPreference -and $script:WRBoundUplink -and (-not $wasOn -or $Restart -or -not (Test-Path -LiteralPath $upFile))) {
    try { Write-WRJson -Object ([pscustomobject]@{ Alias = $script:WRBoundUplink; Time = (Get-Date -Format 's') }) -Path $upFile } catch { L "could not record uplink: $($_.Exception.Message)" 'WARN' }
}
L ("result: state={0} ssid={1} band={2} clients={3} ip137={4}" -f $info.State, $info.Ssid, $info.Band, $info.ClientCount, [bool](Get-NetIPAddress -IPAddress $C.HotspotIp -ErrorAction SilentlyContinue))
if ($info.State -eq 'On' -or $WhatIfPreference) { exit 0 } else { exit 1 }
