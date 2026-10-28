<#
 Fire TV Stick ADB tune-up (no Windows admin). Disables ad/telemetry packages with 'pm disable-user' (reversible) and sets privacy settings.
 Prereq on TV: Settings > My Fire TV > About > click device name 7x (enables Developer options) > Developer options > ADB debugging ON.
 First connect shows "Allow USB debugging?" on the TV - tick "Always allow" and OK.
 Usage:  .\firestick-tune.ps1 -Ip 192.168.137.x -WhatIf | (apply) | -Rollback | -TestOnly
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param([Parameter(Mandatory)][string]$Ip,[switch]$Rollback,[switch]$TestOnly)
$Tools='C:\Users\YOU\Tools'; $Pt=Join-Path $Tools 'platform-tools'; $Adb=Join-Path $Pt 'adb.exe'
$Log=Join-Path $PSScriptRoot 'firestick-tune.log'; $StateF=Join-Path $PSScriptRoot 'firestick-tune.state.txt'
function L($m){ $l="$(Get-Date -f s) $m"; Write-Host $l; Add-Content $Log $l -WhatIf:$false }
if(-not (Test-Path $Adb)){
  $z=Join-Path $env:TEMP 'platform-tools.zip'; L 'downloading Google platform-tools'
  & { $WhatIfPreference=$false; Invoke-WebRequest 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip' -OutFile $z -UseBasicParsing; Expand-Archive $z -DestinationPath $Tools -Force }
}
$target="$($Ip):5555"
if(-not (Test-Connection $Ip -Count 1 -Quiet)){ L "$Ip does not answer ping - is the Fire TV on the hotspot? (check hotspot-status.ps1)"; exit 1 }
Start-Process $Adb -ArgumentList 'start-server' -WindowStyle Hidden -Wait   # start daemon detached so output pipes don't hang
& $Adb connect $target | % { L "adb: $_" }
$state=(& $Adb -s $target get-state 2>&1) -join ' '
if($state -notmatch 'device'){ L "NOT connected ($state). Enable ADB debugging on the Fire TV and accept the prompt on screen."; exit 1 }
$model=(& $Adb -s $target shell getprop ro.product.model).Trim(); $os=(& $Adb -s $target shell getprop ro.build.version.name).Trim(); L "connected: $model $os"
if($TestOnly){ exit 0 }
# Safe list (all reversible). NOT touched: launcher, OTA (com.amazon.device.software.ota*), appstore (com.amazon.venezia), ime, device.messaging, remotes, inputs, Prime Video.
$Pkgs=@(
 'com.amazon.kso.blackbird',          # sponsored banner/row ad sync ("special offers")
 'com.amazon.sneakpeek',              # auto-playing previews
 'com.amazon.hybridadidservice',      # advertising ID
 'com.amazon.tv.acr',                 # automatic content recognition
 'com.amazon.tv.fw.metrics','com.amazon.wirelessmetrics.service','com.amazon.tv.perfcollection','com.amazon.dp.logger', # telemetry
 'com.amazon.shoptv.client','com.amazon.shoptv.firetv.client', # shopping
 'com.amazon.tv.easyupgrade',         # upgrade nags
 'com.amazon.wifilocker'              # uploads Wi-Fi passwords to Amazon
)
$Settings=@(@('global','limit_ad_tracking','1'),@('global','amazon:interest_based_ads','0'),@('global','amazon:device_metrics_opt_in','0'),@('global','amazon:acr_enabled','0'),@('secure','usage_stats','0'))
$installed=(& $Adb -s $target shell pm list packages) -replace '^package:',''
if($Rollback){
  $list= if(Test-Path $StateF){ Get-Content $StateF } else { $Pkgs }
  foreach($p in $list){ if($PSCmdlet.ShouldProcess($p,'pm enable')){ L "enable $p : $((& $Adb -s $target shell pm enable --user 0 $p) -join ' ')" } }
  L 'Rollback of settings: re-enable ad tracking etc. in Settings > Preferences > Privacy if desired.'; exit 0 }
foreach($p in $Pkgs){
  if($installed -notcontains $p){ L "skip $p (not installed)"; continue }
  if($PSCmdlet.ShouldProcess($p,'pm disable-user --user 0')){
    $r=(& $Adb -s $target shell pm disable-user --user 0 $p 2>&1) -join ' '; L "disable $p : $r"
    if($r -match 'disabled'){ if(-not (Select-String -Path $StateF -SimpleMatch $p -Quiet -EA SilentlyContinue)){ Add-Content $StateF $p } } }
}
foreach($s in $Settings){ if($PSCmdlet.ShouldProcess("$($s[0])/$($s[1])","settings put = $($s[2])")){ & $Adb -s $target shell settings put $s[0] $s[1] $s[2]; L "set $($s[0])/$($s[1])=$($s[2])" } }
L 'Done. Optional: install SmartTube (ad-free YouTube) from https://github.com/yuliskov/SmartTube/releases via Downloader app, or: adb install <apk>.'
