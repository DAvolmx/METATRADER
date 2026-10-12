@echo off
cd /d "%~dp0python"
set GM_SYMBOL=XAUUSDmicro
set PYTHONIOENCODING=utf-8
REM set FRED_API_KEY=tu_clave
C:\Python312\python.exe gm_service.py
