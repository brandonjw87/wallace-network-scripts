# Reinstall from Microsoft Store via winget (Store IDs). Microsoft.StartExperiencesApp returns with the next Windows feature/cumulative update or: Get-AppxPackage -AllUsers Microsoft.StartExperiencesApp | % { Add-AppxPackage -Register "$($_.InstallLocation)\AppxManifest.xml" -DisableDevelopmentMode }
winget install --id 9P1J8S7CCWWT --source msstore --accept-package-agreements --accept-source-agreements   # Clipchamp
winget install --id 9PDJDJS743XF --source msstore --accept-package-agreements --accept-source-agreements   # Microsoft Family Safety
Get-AppxPackage -AllUsers Microsoft.StartExperiencesApp -ea 0 | % { Add-AppxPackage -Register "$($_.InstallLocation)\AppxManifest.xml" -DisableDevelopmentMode -ea 0 }
