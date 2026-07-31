@echo off
rem Double-click launcher: plays the game in English.
rem Keeps this window open while you play (it restores the stock files on exit).
setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Play-En.ps1" %*
echo.
pause
