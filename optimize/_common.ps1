# Shared helpers. Backups go to .\backup\<batch>\ and are taken only once (first run), so reruns never overwrite the original state.
$Root = $PSScriptRoot
function Init-Backup($name){ $b=Join-Path $Root "backup\$name"; $first=-not (Test-Path "$b\.done"); New-Item -ItemType Directory $b -Force|Out-Null; return @{Dir=$b;First=$first} }
function Backup-Keys($bk,[string[]]$keys){ if(-not $bk.First){return}; $i=0; foreach($k in $keys){ $i++; $f=Join-Path $bk.Dir ("reg$i.reg"); $null=reg export $k $f /y 2>&1; if(-not (Test-Path $f)){ Add-Content (Join-Path $bk.Dir 'absent.txt') $k } } }
function Backup-Services($bk,[string[]]$names){ if(-not $bk.First){return}; Get-Service $names -ea 0 | select Name,@{n='StartType';e={$_.StartType.ToString()}},@{n='Status';e={$_.Status.ToString()}} | ConvertTo-Json | Set-Content (Join-Path $bk.Dir 'services.json') }
function Finish-Backup($bk){ Set-Content (Join-Path $bk.Dir '.done') (Get-Date) }
function Set-Reg($path,$name,$value,$type='DWord'){ if(-not (Test-Path $path)){New-Item $path -Force|Out-Null}; Set-ItemProperty -Path $path -Name $name -Value $value -Type $type -Force; Write-Host "set $path\$name=$value" }
function Restore-Batch($name){ $b=Join-Path $Root "backup\$name"; if(-not (Test-Path $b)){throw "No backup at $b"}
  Get-ChildItem $b -Filter *.reg | % { reg import $_.FullName; Write-Host "restored $($_.Name)" }
  if(Test-Path "$b\absent.txt"){ Get-Content "$b\absent.txt" | % { $p='Registry::'+$_; if(Test-Path $p){ Remove-Item $p -Recurse -Force; Write-Host "removed (did not exist before) $_" } } }
  if(Test-Path "$b\services.json"){ (Get-Content "$b\services.json" -Raw | ConvertFrom-Json) | % { Set-Service $_.Name -StartupType $_.StartType; if($_.Status -eq 'Running'){Start-Service $_.Name -ea 0}; Write-Host "service $($_.Name) -> $($_.StartType)" } } }
function Assert-Admin{ if(-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')){throw 'Run from an elevated PowerShell.'} }
