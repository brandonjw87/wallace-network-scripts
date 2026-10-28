$log="$env:USERPROFILE\Tools\wallace-roku-v2\logs\move-to-tplink-admin.log"
Start-Transcript $log -Force
$intelWfd = Get-PnpDevice -FriendlyName "*Wi-Fi Direct*" | ? { (Get-PnpDeviceProperty -InstanceId $_.InstanceId DEVPKEY_Device_Parent).Data -like 'PCI\VEN_8086*' }
$intelWfd | ft FriendlyName,InstanceId -auto
$intelWfd | % { Disable-PnpDevice -InstanceId $_.InstanceId -Confirm:$false }
Restart-Service icssvc -Force -EA SilentlyContinue
Disable-NetAdapter -Name 'Wi-Fi 2' -Confirm:$false; Start-Sleep 3; Enable-NetAdapter -Name 'Wi-Fi 2' -Confirm:$false; Start-Sleep 10
Get-PnpDevice -FriendlyName "*Wi-Fi Direct*" | % { "$($_.FriendlyName) $($_.Status) parent=$((Get-PnpDeviceProperty -InstanceId $_.InstanceId DEVPKEY_Device_Parent).Data)" }
Get-NetAdapter | ft Name,InterfaceDescription,Status -auto
Stop-Transcript
