# Batch 2 (user-level). Storage Sense ON: temp files only, monthly; Recycle Bin and Downloads are NEVER auto-cleaned. Notifications kept, but "suggestions/tips" toasts off. Background-app global toggle OFF for Store apps (does not affect Win32 apps like Grok Bot, Chrome, Ollama, AdGuard).
. "$PSScriptRoot\_common.ps1"
$bk=Init-Backup 'batch2_user'
Backup-Keys $bk @('HKCU\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy','HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.Suggested','HKCU\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications')
Finish-Backup $bk
$s='HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy'
Set-Reg $s '01' 1; Set-Reg $s '2048' 30; Set-Reg $s '04' 1; Set-Reg $s '08' 0; Set-Reg $s '256' 0; Set-Reg $s '32' 0; Set-Reg $s '512' 0
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.Suggested' Enabled 0
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' GlobalUserDisabled 1
Write-Host 'Done.'
