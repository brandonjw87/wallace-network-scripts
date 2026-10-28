$log="$env:USERPROFILE\Tools\wifi-perf-admin.log"; $rb="$env:USERPROFILE\Tools\dev-config-backup\wifi-perf-rollback.csv"
function L($m){ "$(Get-Date -f s) $m" | Add-Content $log }
L "=== wifi-perf start"
$want=@(@('Wi-Fi','Preferred Band','3. Prefer 5GHz band'),@('Wi-Fi','Throughput Booster','Enabled'),@('Wi-Fi','MIMO Power Save Mode','No SMPS'),@('Wi-Fi','Roaming Aggressiveness','1. Lowest'),@('Wi-Fi','Mixed Mode Protection','CTS-to-self Enabled'))
$rows=@()
foreach($w in $want){ try{ $p=Get-NetAdapterAdvancedProperty -Name $w[0] -DisplayName $w[1] -EA Stop; $rows+=[pscustomobject]@{Name=$w[0];DisplayName=$w[1];Old=$p.DisplayValue;New=$w[2]}
 if($p.DisplayValue -ne $w[2]){ Set-NetAdapterAdvancedProperty -Name $w[0] -DisplayName $w[1] -DisplayValue $w[2] -NoRestart -EA Stop; L "SET $($w[0]) / $($w[1]): '$($p.DisplayValue)' -> '$($w[2])'" } else { L "OK already $($w[1])=$($w[2])" } } catch { L "FAIL $($w[1]): $_" } }
if(!(Test-Path $rb)){ $rows | Export-Csv $rb -NoType }
foreach($n in 'Wi-Fi','Wi-Fi 2'){ try{ $pm=Get-NetAdapterPowerManagement -Name $n -EA Stop; L "PM $n before AllowTurnOff=$($pm.AllowComputerToTurnOffDevice) SelSusp=$($pm.SelectiveSuspend)"; Set-NetAdapterPowerManagement -Name $n -AllowComputerToTurnOffDevice Disabled -EA Stop; L "PM $n AllowComputerToTurnOffDevice -> Disabled" } catch { L "PM ${n}: $_" } }
try{ foreach($sch in (powercfg /getactivescheme) -replace '.*GUID: (\S+).*','$1'){ powercfg /setacvalueindex $sch 19cbb8fa-5279-450e-9fac-8a3d5fedd0c1 12bbebe6-58d6-4636-95bb-3217ef867c1a 0; powercfg /setdcvalueindex $sch 19cbb8fa-5279-450e-9fac-8a3d5fedd0c1 12bbebe6-58d6-4636-95bb-3217ef867c1a 0; powercfg /setactive $sch; L "powercfg wireless power saving -> Maximum Performance (AC+DC) on $sch" } } catch { L "powercfg: $_" }
L "=== wifi-perf done (no adapter restart; hotspot untouched)"

