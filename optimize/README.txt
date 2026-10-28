NOT EXECUTED. Run user scripts in a normal PowerShell, *_admin.ps1 in an elevated PowerShell:  powershell -ExecutionPolicy Bypass -File .\batch1_user.ps1
First run of each script saves a backup in .\backup\<batch>\ (never overwritten on reruns). *_undo.ps1 restores it. Suggested order: batch1_user, batch1_admin, batch2_user, batch2_admin, batch3_user, (optional) batch3_admin, then restart.
