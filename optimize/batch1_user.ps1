# Batch 1 (user-level, no admin). Visual effects best-performance (keeps font smoothing + thumbnails), transparency/animations off, tips/ads/suggested apps off, Widgets button off. Sign out/in to apply fully.
. "$PSScriptRoot\_common.ps1"
$bk=Init-Backup 'batch1_user'
Backup-Keys $bk @('HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects','HKCU\Control Panel\Desktop','HKCU\Control Panel\Desktop\WindowMetrics','HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced','HKCU\Software\Microsoft\Windows\DWM','HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize','HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager','HKCU\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement','HKCU\Software\Microsoft\Windows\CurrentVersion\Privacy')
Finish-Backup $bk
# Visual effects: Custom (3) with best-performance mask but font smoothing + thumbnails kept
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' VisualFXSetting 3
Set-Reg 'HKCU:\Control Panel\Desktop' UserPreferencesMask ([byte[]](0x90,0x12,0x03,0x80,0x10,0x00,0x00,0x00)) Binary
Set-Reg 'HKCU:\Control Panel\Desktop' FontSmoothing '2' String
Set-Reg 'HKCU:\Control Panel\Desktop' MenuShowDelay '100' String
Set-Reg 'HKCU:\Control Panel\Desktop\WindowMetrics' MinAnimate '0' String
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' TaskbarAnimations 0
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' ListviewAlphaSelect 0
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' ListviewShadow 0
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' IconsOnly 0
Set-Reg 'HKCU:\Software\Microsoft\Windows\DWM' EnableAeroPeek 0
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' EnableTransparency 0
# Tips, suggestions, ads, silent app installs
$c='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
foreach($n in 'SubscribedContent-338388Enabled','SubscribedContent-338389Enabled','SubscribedContent-310093Enabled','SubscribedContent-338393Enabled','SubscribedContent-353694Enabled','SubscribedContent-353696Enabled','SystemPaneSuggestionsEnabled','SilentInstalledAppsEnabled','SoftLandingEnabled','RotatingLockScreenOverlayEnabled','PreInstalledAppsEnabled','OemPreInstalledAppsEnabled'){ Set-Reg $c $n 0 }
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement' ScoobeSystemSettingEnabled 0
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' Start_IrisRecommendations 0
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' ShowSyncProviderNotifications 0
# Widgets taskbar button (may be ACL-protected on some builds; failure is harmless)
try{ Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' TaskbarDa 0 }catch{ Write-Warning 'TaskbarDa protected; turn Widgets off in Settings > Personalization > Taskbar.' }
Write-Host 'Done. Sign out/in (or restart Explorer) to see all changes.'
