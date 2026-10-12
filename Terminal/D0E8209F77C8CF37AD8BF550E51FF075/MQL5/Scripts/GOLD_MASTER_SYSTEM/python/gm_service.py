"""
gm_service.py — servicio headless de producción (sin dashboard):
calcula inteligencia + capa cuantitativa cada 20 s y la publica a MT5 (intel.txt),
con log rotativo, reconexión automática a MT5 y latido (service_heartbeat.txt).
Uso:  python gm_service.py   (o GM_START_SERVICE.bat)
"""
import os, sys, time, json, logging
from logging.handlers import RotatingFileHandler
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, HERE)
os.makedirs(os.path.join(HERE, "logs"), exist_ok=True)
logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
                    handlers=[RotatingFileHandler(os.path.join(HERE, "logs", "service.log"), maxBytes=2_000_000, backupCount=5),
                              logging.StreamHandler(sys.stdout)])
log = logging.getLogger("gm_service")
import MetaTrader5 as mt5
from gm_intel import IntelEngine, GM_DIR

SYMBOL = os.getenv("GM_SYMBOL", "XAUUSDmicro")
EVERY = int(os.getenv("GM_EVERY_S", "20"))
RETRAIN_H = float(os.getenv("GM_RETRAIN_H", "6"))      # re-entrenar cada N horas (24/7)
import threading
def retrain_loop():
    from gm_retrain import retrain
    while True:
        try:
            if ensure_mt5():
                r = retrain(SYMBOL); log.info(f"RETRAIN -> {r}")
        except Exception as ex:
            log.exception(f"retrain: {ex}")
        time.sleep(RETRAIN_H*3600)

def ensure_mt5():
    if mt5.terminal_info() is not None: return True
    ok = mt5.initialize()
    log.info(f"MT5 initialize -> {ok} {mt5.last_error() if not ok else ''}")
    if ok: mt5.symbol_select(SYMBOL, True)
    return ok

if __name__ == "__main__":
    log.info(f"GOLD MASTER service iniciado · símbolo {SYMBOL} · cada {EVERY}s · bridge {GM_DIR}")
    eng = None
    # Candidate research is a separate offline command: avoid concurrent MT5 access
    # and parameter changes while the service is evaluating the market.
    while True:
        t0 = time.time()
        try:
            if ensure_mt5():
                if eng is None:
                    eng = IntelEngine(SYMBOL)
                    from gm_micro import MicroMonitor
                    eng.micro = MicroMonitor(SYMBOL, GM_DIR).start()
                s = eng.compute()
                log.info(f"composite={s.get('composite')} risk={s.get('risk_mult')} block={s.get('block_trading')} "
                         f"regime={s.get('regime_q')} vol={s.get('vol_fcst')}% port_risk={s.get('port_risk_pct')}%")
            mic = getattr(eng, "micro", None) if eng else None
            if mic and time.time() - mic.last_cycle > 30:
                if mic.stop():
                    log.warning("hilo micro detenido → se relanza")
                    from gm_micro import MicroMonitor
                    eng.micro = MicroMonitor(SYMBOL, GM_DIR).start()
                else:
                    log.error("hilo micro no responde; no crear un segundo escritor")
            with open(os.path.join(GM_DIR, "service_heartbeat.txt"), "w") as f:
                f.write(json.dumps({"ts": int(time.time()), "ok": eng is not None and mt5.terminal_info() is not None}))
        except Exception as ex:
            log.exception(f"ciclo: {ex}")
            try: mt5.shutdown()
            except Exception: pass
        time.sleep(max(1, EVERY - (time.time() - t0)))
