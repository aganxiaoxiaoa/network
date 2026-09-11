@echo off
setlocal
title Network Safe Recovery (Wi-Fi 701/702 + Wireless DHCP Renew ONLY)
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0app\NetworkSafeRecovery.ps1" %*
set "RC=%ERRORLEVEL%"
echo.
echo [Exit Code] %RC%
echo   0 = recovered   1 = environment/error   2 = still offline   3 = cancelled
echo.
pause
endlocal
