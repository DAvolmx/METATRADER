"""
gm_supervisor.py — vigilante de producción. Mantiene vivos el servicio y el dashboard:
  · arranca ambos como procesos hijos y los reinicia si se caen (backoff progresivo)
  · reinicia el servicio si su latido (service_heartbeat.txt) tiene más de 120 s
  · reinicia el dashboard si http://127.0.0.1:8050 no responde 3 veces seguidas
  · si el monitor de micro-variaciones (micro.json) se congela > 60 s, reinicia el servicio
  · si MT5 tiene gráficos sin actualizar, el Guardian los recarga solo (AutoHealCharts)
Uso: GM_START_ALL.bat (lo lanza automáticamente)
"""
import os, sys, time, json, subprocess, logging, urllib.request
from logging.handlers import RotatingFileHandler
HERE = os.path.dirname(os.path.abspath(__file__)); os.makedirs(os.path.join(HERE, "logs"), exist_ok=True)
logging.basicConfig(level=logging.INFO, format="%(asctime)s [SUPERVISOR] %(message)s",
                    handlers=[RotatingFileHandler(os.path.join(HERE, "logs", "supervisor.log"), maxBytes=1_000_000, backupCount=3),
                              logging.StreamHandler(sys.stdout)])
log = logging.getLogger()
GM_DIR = os.path.join(os.environ.get("APPDATA", ""), "MetaQuotes", "Terminal", "Common", "Files", "GoldMaster")
PY = sys.executable
NOWIN = getattr(subprocess, "CREATE_NO_WINDOW", 0)

class Child:
    def __init__(self, name, script, env=None):
        self.name, self.script, self.env = name, script, env or {}
        self.p = None; self.fails = 0; self.started = 0
    def start(self):
        env = dict(os.environ, PYTHONIOENCODING="utf-8", **self.env)
        out = open(os.path.join(HERE, "logs", f"{self.name}.out.log"), "a", encoding="utf-8")
        self.p = subprocess.Popen([PY, self.script], cwd=HERE, env=env, stdout=out, stderr=subprocess.STDOUT, creationflags=NOWIN)
        self.started = time.time(); log.info(f"{self.name} iniciado (pid {self.p.pid})")
    def restart(self, why):
        log.warning(f"reiniciando {self.name}: {why}")
        try: self.p.kill()
        except Exception: pass
        self.fails += 1; time.sleep(min(60, 2**min(self.fails, 5))); self.start()
    def alive(self): return self.p is not None and self.p.poll() is None

def age(fname, key="ts"):
    try:
        with open(os.path.join(GM_DIR, fname)) as f: return time.time() - float(json.load(f).get(key, 0))
    except Exception: return 1e9

def http_ok(url="http://127.0.0.1:8050"):
    try: return urllib.request.urlopen(url, timeout=5).status == 200
    except Exception: return False

if __name__ == "__main__":
    import socket
    _lock = socket.socket()
    try: _lock.bind(("127.0.0.1", 8059))            # una sola instancia del supervisor
    except OSError:
        log.info("ya hay un supervisor en marcha → salgo"); sys.exit(0)
    svc = Child("service", "gm_service.py")
    dash = Child("dashboard", "GOLD_MASTER_dashboard_v3.py", {"GM_FOLLOW_SERVICE": "1"})
    svc.start(); time.sleep(8); dash.start(); dash_bad = 0
    while True:
        time.sleep(15)
        try:
            if not svc.alive(): svc.restart(f"terminó (código {svc.p.returncode})")
            elif time.time() - svc.started > 180 and age("service_heartbeat.txt") > 120: svc.restart("latido congelado")
            elif time.time() - svc.started > 240 and age("micro.json", "micro_ts") > 60: svc.restart("monitor micro congelado")
            else: svc.fails = 0
            if not dash.alive(): dash.restart(f"terminó (código {dash.p.returncode})")
            elif time.time() - dash.started > 60:
                dash_bad = 0 if http_ok() else dash_bad + 1
                if dash_bad >= 3: dash.restart("no responde HTTP"); dash_bad = 0
        except Exception as ex:
            log.exception(f"ciclo: {ex}")
