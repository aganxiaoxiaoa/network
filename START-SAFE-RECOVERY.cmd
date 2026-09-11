@echo off
setlocal
title Network Safe Recovery (Wi-Fi 701/702 + Wireless DHCP Renew ONLY)
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0app\NetworkSafeRecovery.ps1" %*
set "RC=%ERRORLEVEL%"
echo.
echo [Exit Code] %RC%
echo   0 = OK (recovered, already online, or -WhatIf dry run)
echo   1 = environment/error, nothing was changed
echo   2 = attempted but still offline
echo   3 = cancelled by user
echo.
pause
endlocal & exit /b %RC%
