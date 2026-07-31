@echo off
rem Double-click installer for the Mushoku Tensei PC English patch.
rem Just runs the PowerShell installer with the execution policy bypassed.
setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-EnPatch.ps1" %*
echo.
pause
