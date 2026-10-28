# WALLACE hotspot watchdog. Run by scheduled task 'Wallace-Roku Watchdog' (Brandon, Highest, interactive).
# If hotspot is off or 192.0.2.11 is missing: restart SharedAccess/icssvc, then run start-hotspot.ps1.
$ErrorActionPreference = 'Continue'
$d   = $PSScriptRoot
$log = Join-Path $d 'hotspot-watchdog.log'
function W($m){ "$(Get-Date -f s) $m" | Add-Content -Path $log }
# keep log small
try { if ((Get-Item $log -EA Stop).Length -gt 1MB) { Move-Item $log "$log.old" -Force } } catch {}

function Get-HotspotState {
  try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $null=[Windows.Networking.Connectivity.NetworkInformation,Windows.Networking.Connectivity,ContentType=WindowsRuntime]
    $null=[Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager,Windows.Networking.NetworkOperators,ContentType=WindowsRuntime]
    $p=[Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile()
    if (-not $p) { return 'NoProfile' }
    return [string]([Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile($p).TetheringOperationalState)
  } catch { return "Err:$($_.Exception.Message)" }
}

$state = Get-HotspotState
$ipOk  = [bool](Get-NetIPAddress -IPAddress 192.0.2.11 -EA SilentlyContinue)
if ($state -eq 'On' -and $ipOk) { exit 0 }   # healthy: no log spam

W "UNHEALTHY state=$state ip137=$ipOk -> restarting"
foreach ($s in 'SharedAccess','icssvc') {
  try { Set-Service $s -StartupType Automatic -EA SilentlyContinue; Restart-Service $s -Force -EA Stop; W "restarted $s" }
  catch { try { Start-Service $s -EA Stop; W "started $s" } catch { W "svc $s err: $($_.Exception.Message)" } }
}
Start-Sleep 5
try { $out = & (Join-Path $d 'start-hotspot.ps1') 2>&1 | Out-String; W ("start-hotspot: " + ($out -replace '\s+',' ').Trim()) }
catch { W "start-hotspot err: $($_.Exception.Message)" }
Start-Sleep 5
W "after: state=$(Get-HotspotState) ip137=$([bool](Get-NetIPAddress -IPAddress 192.0.2.11 -EA SilentlyContinue))"
