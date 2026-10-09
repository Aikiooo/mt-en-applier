@echo off
rem Undo the patch: removes the patched language pack so the game re-downloads Japanese.
setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-EnPatch.ps1" -Restore
echo.
pause
