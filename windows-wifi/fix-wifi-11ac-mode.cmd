@echo off
powershell -NoProfile -Command "Reset-NetAdapterAdvancedProperty -Name 'Wi-Fi' -RegistryKeyword IEEE11nMode; Get-NetAdapterAdvancedProperty -Name 'Wi-Fi' -RegistryKeyword IEEE11nMode"
pause
