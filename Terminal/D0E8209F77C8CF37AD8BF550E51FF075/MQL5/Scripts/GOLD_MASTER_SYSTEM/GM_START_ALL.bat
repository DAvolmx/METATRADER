@echo off
REM GM_Deploy launches this single local entry point for observer, replay and dashboard.
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0INICIAR_OBSERVATORIO.ps1" -OpenBrowser
if errorlevel 1 pause
