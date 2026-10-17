@echo off
title MT English Patch for iPhone
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Installer-iOS.ps1" %*
echo.
pause
