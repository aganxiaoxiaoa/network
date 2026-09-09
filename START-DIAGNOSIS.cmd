@echo off
setlocal
title Network Diagnosis Toolkit (Read-Only Portable USB)
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0app\NetworkDiagnostics.ps1" %*
endlocal
