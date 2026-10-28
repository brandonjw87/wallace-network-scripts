Start-Transcript "$env:USERPROFILE\Tools\wallace-roku-v2\logs\restore-intel-wfd-admin.log" -Force
Get-PnpDevice -FriendlyName "*Wi-Fi Direct*" | % { Enable-PnpDevice -InstanceId $_.InstanceId -Confirm:$false }
Start-Sleep 5
Get-PnpDevice -FriendlyName "*Wi-Fi Direct*" | ft FriendlyName,Status -auto
Stop-Transcript
