# Batch 3 (machine-level, ADMIN). Post-reset disk cleanup: component store cleanup (keeps ability to uninstall current updates - no /ResetBase), and remove Windows.old ONLY if you are sure you do not need to roll back the reset. Not reversible (by nature); no user files touched.
. "$PSScriptRoot\_common.ps1"; Assert-Admin
DISM /Online /Cleanup-Image /StartComponentCleanup
if(Test-Path C:\Windows.old){ Write-Host 'C:\Windows.old exists. Run Settings > System > Storage > Temporary files > "Previous Windows installation(s)" to remove it once you are happy with the reset.' }
