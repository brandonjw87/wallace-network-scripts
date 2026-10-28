# WALLACE DNS bind guard (3.2.0). Runs as SYSTEM at startup + every 2 min.
# Makes AdGuard Home listen on the hotspot gateway 192.0.2.11 directly (a specific bind wins over the Windows ICS DNS proxy's
# wildcard socket), so AdGuard sees every hotspot device's real IP. Falls back to the old wildcard bind automatically if
# AdGuard cannot start or resolve. Never prints secrets (only the bind_hosts lines are touched/logged).
param([switch]$Force)
$ErrorActionPreference = 'Continue'
$y = 'C:\Users\YOU\Tools\AdGuardHome\AdGuardHome.yaml'; $log = 'C:\ProgramData\WALLACE Admin\dns-bind-guard.log'
New-Item -ItemType Directory -Force (Split-Path $log) | Out-Null
function L($m) { Add-Content $log "$(Get-Date -f s) $m"; $c = Get-Content $log; if ($c.Count -gt 400) { $c[-300..-1] | Set-Content $log } }
function Present($ip) { [bool](Get-NetIPAddress -IPAddress $ip -ErrorAction SilentlyContinue | ?{ $_.AddressState -eq 'Preferred' }) }
function GetBinds { $t = [IO.File]::ReadAllText($y); $m = [regex]::Match($t, '(?m)^  bind_hosts:\r?\n((?:    - .*\r?\n)+)'); if (!$m.Success) { return $null }; @($m.Groups[1].Value -split "`n" | %{ $_.Trim() } | ?{ $_ } | %{ $_.Substring(2).Trim() }) }
function SetBinds($list) { $t = [IO.File]::ReadAllText($y); $nl = if ($t.Contains("`r`n")) { "`r`n" } else { "`n" }
  $body = ($list | %{ "    - $_$nl" }) -join ''; $t2 = [regex]::Replace($t, '(?m)^(  bind_hosts:\r?\n)((?:    - .*\r?\n)+)', { param($m) $m.Groups[1].Value + $body }, 1)
  if ($t2 -eq $t) { return $false }; [IO.File]::WriteAllText($y, $t2, (New-Object Text.UTF8Encoding $false)); $true }
function Healthy { try { Start-Sleep 4; for ($i = 0; $i -lt 8; $i++) { if ((Get-Service AdGuardHome).Status -eq 'Running') { try { Resolve-DnsName example.com -Server 127.0.0.1 -DnsOnly -QuickTimeout -ErrorAction Stop | Out-Null; return $true } catch {} }; Start-Sleep 2 } } catch {}; $false }

# ---- 3.2.0 per-device sync + messaging guard (runs every time, independent of the WALLACE Admin app) ----
function SyncAndProtect {
  try {
    $t = Get-Content 'C:\Users\YOU\Tools\AdGuardHome\ADMIN-LOGIN.txt' -Raw; $u = [regex]::Match($t, '(?i)user\w*\s*[:=]\s*(\S+)').Groups[1].Value; $pw = [regex]::Match($t, '(?i)pass\w*\s*[:=]\s*(\S+)').Groups[1].Value
    $H = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${u}:$pw")) }; Remove-Variable t, pw
    $B = 'http://127.0.0.1:3000/control/'
    # (a) messaging allowlist must be first and complete
    $doms = Get-Content 'C:\ProgramData\WALLACE Admin\messaging-domains.txt' | ?{ $_.Trim() }
    $begin = '! Messaging:protected begin (WALLACE: messaging/calls/OTP are NEVER blocked - do not edit)'; $end = '! Messaging:protected end'
    $block = @($begin) + @($doms | %{ "@@||$_^`$important" }) + @('@@/^(instantmessaging|rcs|tachyon|messages)[a-z0-9-]*\.googleapis\.com$/$important', $end)
    $rules = @((Invoke-RestMethod ($B + 'filtering/status') -Headers $H).user_rules)
    $okBlock = $rules.Count -ge $block.Count -and (($rules[0..($block.Count - 1)] -join "`n") -eq ($block -join "`n"))
    if (-not $okBlock) {
      $s = [array]::IndexOf($rules, ($rules | ?{ $_ -like '! Messaging:protected begin*' } | select -First 1)); $e = [array]::IndexOf($rules, $end)
      $rest = @(for ($i = 0; $i -lt $rules.Count; $i++) { if ($s -ge 0 -and $e -ge $s -and $i -ge $s -and $i -le $e) { continue }; $rules[$i] })
      Invoke-RestMethod ($B + 'filtering/set_rules') -Method POST -Headers $H -ContentType 'application/json' -Body (@{ rules = @($block + $rest) } | ConvertTo-Json -Depth 4) | Out-Null
      L 'messaging allowlist was missing/changed -> restored at top' }
    # (b) keep each MAC-identified client's current hotspot IP(s) in its ids so AdGuard applies the right profile (exempt phone, filtered Rokus)
    $nb = @(Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue | ?{ $_.IPAddress -like '192.168.137.*' -and $_.IPAddress -ne '192.0.2.11' -and $_.IPAddress -ne '192.0.2.27' -and $_.State -notin 'Unreachable', 'Incomplete' -and $_.LinkLayerAddress -match '^[0-9A-F]{2}(-[0-9A-F]{2}){5}$' -and $_.LinkLayerAddress -ne '00-00-5E-00-53-06' })
    foreach ($c in @((Invoke-RestMethod ($B + 'clients') -Headers $H).clients)) {
      $macs = @($c.ids | ?{ $_ -match '^([0-9a-f]{2}[:-]){5}[0-9a-f]{2}$' } | %{ $_.ToUpper().Replace(':', '-') }); if (-not $macs) { continue }
      $cur = @($nb | ?{ $macs -contains $_.LinkLayerAddress } | %{ $_.IPAddress } | sort -Unique); if (-not $cur) { continue }
      $old137 = @($c.ids | ?{ $_ -like '192.168.137.*' } | sort -Unique)
      if (($old137 -join ',') -eq ($cur -join ',')) { continue }
      $c.ids = @(@($c.ids | ?{ $_ -notlike '192.168.137.*' }) + $cur)
      $data = $c | Select-Object * -ExcludeProperty disallowed, disallowed_rule, whois_info
      Invoke-RestMethod ($B + 'clients/update') -Method POST -Headers $H -ContentType 'application/json' -Body (@{ name = $c.name; data = $data } | ConvertTo-Json -Depth 6) | Out-Null
      L "client '$($c.name)' hotspot IP(s) [$($old137 -join ',')] -> [$($cur -join ',')]" }
  } catch { L ("sync error: " + $_.Exception.Message) }
}
$want = @('127.0.0.1', '::1'); foreach ($ip in '192.0.2.13', '192.0.2.11') { if (Present $ip) { $want += $ip } }
$fallback = @('0.0.0.0', '::')
$cur = GetBinds; if ($null -eq $cur) { L 'bind_hosts block not found - no change'; SyncAndProtect; exit 0 }
$svcOk = (Get-Service AdGuardHome).Status -eq 'Running'
if (-not $Force -and $svcOk -and (($cur -join ',') -eq ($want -join ','))) { SyncAndProtect; exit 0 }
if (-not $Force -and $svcOk -and (($cur -join ',') -eq ($fallback -join ',')) -and (Test-Path 'C:\ProgramData\WALLACE Admin\dns-bind-fallback.flag')) {
  if ((Get-Item 'C:\ProgramData\WALLACE Admin\dns-bind-fallback.flag').LastWriteTime -gt (Get-Date).AddMinutes(-30)) { SyncAndProtect; exit 0 } }
L "bind change: [$($cur -join ', ')] -> [$($want -join ', ')]"
if (SetBinds $want) { Restart-Service AdGuardHome -Force -ErrorAction SilentlyContinue } elseif (-not $svcOk) { Start-Service AdGuardHome -ErrorAction SilentlyContinue }
if (Healthy) { L 'AdGuard healthy on specific binds'; Remove-Item 'C:\ProgramData\WALLACE Admin\dns-bind-fallback.flag' -ErrorAction SilentlyContinue; SyncAndProtect; exit 0 }
L 'AdGuard NOT healthy on specific binds -> falling back to wildcard (0.0.0.0, ::)'
[void](SetBinds $fallback); Restart-Service AdGuardHome -Force -ErrorAction SilentlyContinue; Set-Content 'C:\ProgramData\WALLACE Admin\dns-bind-fallback.flag' (Get-Date -f s)
if (Healthy) { L 'fallback healthy' } else { L 'FALLBACK ALSO UNHEALTHY - check AdGuard' }
SyncAndProtect

