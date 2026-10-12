"""Verify the exact MT5 data directory before starting local services."""
import json
import os
from pathlib import Path
import sys
import MetaTrader5 as mt5

expected=Path(__file__).resolve().parents[4]
terminal=os.getenv('GM_TERMINAL_PATH','C:/Program Files/MetaTrader 5/terminal64.exe')
try:
    if not mt5.initialize(terminal,timeout=10000):
        raise SystemExit('No se pudo conectar al terminal seleccionado: '+str(mt5.last_error()))
    info=mt5.terminal_info()
    if info is None or not info.connected:
        raise SystemExit('El terminal no está conectado al servidor del broker.')
    if os.path.normcase(os.path.realpath(info.data_path)) != os.path.normcase(os.path.realpath(expected)):
        raise SystemExit('Carpeta MT5 distinta de la autorizada; inicio cancelado.')
    print(json.dumps({'connected':True,'terminal':terminal,'data_path':info.data_path,'execution':'disabled'},ensure_ascii=False))
finally:
    mt5.shutdown()
