. "$PSScriptRoot\_common.ps1"; Assert-Admin; Restore-Batch 'batch2_admin'
$t="$PSScriptRoot\backup\batch2_admin\tasks.json"; if(Test-Path $t){ $j=Get-Content $t -Raw|ConvertFrom-Json; if($j.State -ne 'Disabled'){ Enable-ScheduledTask -TaskPath $j.TaskPath -TaskName $j.TaskName|Out-Null } }
Write-Host 'Restored.'
