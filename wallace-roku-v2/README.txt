Wallace-Roku v2  -  Wi-Fi hotspot + AdGuard Home ad blocking for the Rokus / Fire TV
=====================================================================================
Folder: C:\Users\YOU\Tools\wallace-roku-v2\      (Windows PowerShell 5.1; no secrets stored here)

HOW IT WORKS
  Rokus join the Mobile Hotspot "Wallace-Roku" (5 GHz, gateway 192.0.2.11).
  Windows ICS hands them DHCP and answers their DNS on 192.0.2.11:53, then FORWARDS those queries to
  whatever DNS servers the laptop's ACTIVE UPLINK adapter uses (Ethernet when plugged in, else Wi-Fi; lowest
  route metric with a gateway). So EVERY uplink adapter (config UplinkAliases) must use DNS 127.0.0.1
  (AdGuard Home) - otherwise hotspot clients silently bypass the ad blocker. AdGuard Home sends queries
  upstream over DoH (Cloudflare + Quad9 in parallel, DNSSEC, optimistic cache).
  Laptop LAN IP: 192.0.2.28 (router reservation). AdGuard web UI: http://192.0.2.28:3000

FILES
  config.json         all non-secret settings (SSID, IPs, ports, log paths, PATH of the passphrase file)
  lib.ps1             shared functions: logging+rotation, JSON status, WinRT tethering, DNS probes, health
  start-hotspot.ps1   idempotent hotspot start (-Restart, -Reconfigure, -WhatIf); 5GHz with Auto fallback
  watchdog.ps1        run by task 'Wallace-Roku Watchdog'; quiet when healthy; escalating repairs
                      L1 targeted service start / DNS fix / start tethering -> L2 ICS restart -> L3 hotspot restart
                      (-CheckOnly or -WhatIf = report only)
  status.ps1          one-screen dashboard (no admin)
  apply-admin.ps1     ONE-TIME elevated migration (backs up first, auto-restores AdGuard on failure)
  rollback-admin.ps1  undo apply-admin from its backup folder (elevated)
  logs\               watchdog.log, start-hotspot.log, apply-admin.log, status.json, watchdog.state.json

COMMANDS
  Status:        powershell -ExecutionPolicy Bypass -File C:\Users\YOU\Tools\wallace-roku-v2\status.ps1
  Check only:    powershell -ExecutionPolicy Bypass -File C:\Users\YOU\Tools\wallace-roku-v2\watchdog.ps1 -CheckOnly
  Start hotspot: powershell -ExecutionPolicy Bypass -File C:\Users\YOU\Tools\wallace-roku-v2\start-hotspot.ps1
  Apply (UAC):   powershell -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -NoExit -File C:\Users\YOU\Tools\wallace-roku-v2\apply-admin.ps1'"
  Rollback (UAC):powershell -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -NoExit -File C:\Users\YOU\Tools\wallace-roku-v2\rollback-admin.ps1'"
  Result of apply: apply-result.txt in this folder; every change also logged in ..\dev-config-backup\CHANGES.md

NOTES / KNOWN LIMITS
  * Hotspot passphrase stays in ..\roku-dhcp\HOTSPOT-PASSWORD.txt (only its path is in config.json).
  * AdGuard sees all hotspot clients as 127.0.0.1 (ICS DNS proxy), so per-device stats are not possible.
  * Open DHCP Server (main-LAN Roku DHCP) only binds to a STATIC interface. The laptop now gets .210 by
    router reservation (DHCP), so OpenDHCPServer stays idle ("No Static Interface ready"). Hotspot is unaffected.
  * ratelimit_whitelist in AdGuard accepts single IPs only (no CIDR), so local IPs are listed individually.
  * Uplink failover: start-hotspot records the shared uplink in logs\hotspot-uplink.json; if the active uplink
    changes (Ethernet unplugged), the watchdog check HotspotUplink fails and L1 runs start-hotspot -Restart.
  * apply-admin.ps1 / rollback-admin.ps1 (one-time migration) still only handle WifiAlias.
  * Legacy scripts in ..\roku-dhcp are kept (firestick-tune.ps1, roku-adblock.ps1, add-*-rules.ps1 still usable).
