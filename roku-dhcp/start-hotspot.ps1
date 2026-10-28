$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$asTask=([System.WindowsRuntimeSystemExtensions].GetMethods()|?{$_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'})[0]
function Await($op,[Type]$t){$task=$asTask.MakeGenericMethod($t).Invoke($null,@($op));$task.Wait(-1)|Out-Null;$task.Result}
$null=[Windows.Networking.Connectivity.NetworkInformation,Windows.Networking.Connectivity,ContentType=WindowsRuntime]
$null=[Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager,Windows.Networking.NetworkOperators,ContentType=WindowsRuntime]
$p=[Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile()
$m=[Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile($p)
$pwf='C:\path\to\hotspot-passphrase.txt'
$cfg=$m.GetCurrentAccessPointConfiguration()
if($cfg.Ssid -ne 'Wallace-Roku' -or $env:HS_RECONF){
 $cfg.Ssid='Wallace-Roku'; $cfg.Passphrase=(Get-Content $pwf -Raw).Trim()
 try{ if($cfg.IsBandSupported([Windows.Networking.NetworkOperators.TetheringWiFiBand]::FiveGigahertz)){$cfg.Band='FiveGigahertz'} else {$cfg.Band='Auto'} }catch{}
 $aa=([System.WindowsRuntimeSystemExtensions].GetMethods()|?{$_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction'})[0]; $aa.Invoke($null,@($m.ConfigureAccessPointAsync($cfg))).Wait(-1)|Out-Null
}
try{  }catch{}
try{ [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::DisableNoConnectionsTimeout() }catch{ "timeout-disable err: $_" }
if($m.TetheringOperationalState -ne 'On'){ $r=Await ($m.StartTetheringAsync()) ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult]); "start: $($r.Status) $($r.AdditionalErrorMessage)" }
"state: $($m.TetheringOperationalState)"
$c=$m.GetCurrentAccessPointConfiguration(); "ssid: $($c.Ssid) band: $(try{$c.Band}catch{'n/a'})"


