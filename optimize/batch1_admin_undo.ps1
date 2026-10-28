. "$PSScriptRoot\_common.ps1"; Assert-Admin
$b="$PSScriptRoot\backup\batch1_admin"; Restore-Batch 'batch1_admin'
# Undo powercfg: High performance plan defaults (what Brandon had), then restore its timeouts to Windows defaults
powercfg /restoredefaultschemes  # resets built-in plans to default values (also re-selects Balanced)
powercfg /setactive SCHEME_MIN
Write-Host "Original values for reference: $b\powercfg_query.txt"
