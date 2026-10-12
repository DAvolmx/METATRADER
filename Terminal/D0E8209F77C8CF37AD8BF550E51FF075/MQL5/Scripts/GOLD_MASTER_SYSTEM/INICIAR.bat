@echo off
title GOLD MASTER - INICIAR
REM 1) Abre MT5 con todos los graficos, EAs e indicadores (si no esta abierto)
REM 2) Arranca supervisor = servicio cuantitativo + dashboard   3) Abre el navegador
cd /d "%~dp0"
tasklist /FI "IMAGENAME eq terminal64.exe" | find /I "terminal64.exe" >nul
if errorlevel 1 (
  echo Abriendo MetaTrader 5 y desplegando GOLD MASTER...
  start "" "C:\Program Files\MetaTrader 5\terminal64.exe" /config:"%~dp0gm_iniciar.ini"
  timeout /t 30 /nobreak >nul
) else (
  echo MetaTrader 5 ya esta abierto - se usan sus graficos actuales.
)
echo Arrancando servicio + dashboard...
call "%~dp0GM_START_ALL.bat"
echo Listo: http://127.0.0.1:8050
