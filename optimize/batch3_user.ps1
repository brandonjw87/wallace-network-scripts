# Batch 3 (user-level). Remove leftover consumer apps for this user only: Clipchamp, Microsoft Family, Start Experiences (Start menu promo). Reinstall any via Store/winget (see undo).
. "$PSScriptRoot\_common.ps1"
$bk=Init-Backup 'batch3_user'
$apps='Clipchamp.Clipchamp','MicrosoftCorporationII.MicrosoftFamily','Microsoft.StartExperiencesApp'
if($bk.First){ Get-AppxPackage | ? Name -in $apps | select Name,PackageFullName,PackageFamilyName | ConvertTo-Json | Set-Content "$($bk.Dir)\appx.json" }
Finish-Backup $bk
foreach($a in $apps){ $p=Get-AppxPackage -Name $a; if($p){ $p | Remove-AppxPackage; Write-Host "removed $a" } else { Write-Host "$a already absent" } }
