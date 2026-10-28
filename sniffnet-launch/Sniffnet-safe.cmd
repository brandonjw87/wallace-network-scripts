@echo off
set ICED_BACKEND=tiny-skia
set WGPU_BACKEND=dx12
if not exist %SystemRoot%\System32\Npcap\wpcap.dll (
  msg %USERNAME% Sniffnet needs Npcap. Run the npcap installer on your Desktop first.
  exit /b 1
)
start "" "C:\Program Files\Sniffnet\sniffnet.exe"
