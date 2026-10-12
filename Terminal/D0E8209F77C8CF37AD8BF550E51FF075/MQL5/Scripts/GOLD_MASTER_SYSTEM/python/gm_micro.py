"""
gm_micro.py — monitor de MICRO-VARIACIONES en tiempo real (1 muestra/segundo)
  ORO  : desequilibrio de flujo de órdenes (OFI, Cont-Kukanov-Stoikov 2014) con bid/ask de cada tick,
         velocidad de ticks (z), spread (z), micro-tendencia (EWMA 5 s vs 60 s), retorno 10 s / 60 s (z)
  DXY  : índice sintético ICE recalculado CADA SEGUNDO con los 6 pares (EUR, JPY, GBP, CAD, SEK, CHF)
         · z-score del movimiento de 10 s / 60 s → "DXY SHOCK" cuando |z60| > 2.5
         · beta oro↔DXY y correlación en ventana móvil de 30 min (retornos de 5 s)
         · lead-lag: correlación cruzada 1-15 s → si el dólar se adelanta, movimiento esperado del oro
  Publica en Common\\Files\\GoldMaster\\micro.json y lo fusiona en intel.txt (dxy_shock, micro_bias, ...).
  Alertas: log + alerts.csv (+ Telegram opcional con TELEGRAM_TOKEN y TELEGRAM_CHAT).
"""
import os, time, json, threading, logging, collections
import numpy as np
import MetaTrader5 as mt5
from datetime import datetime, timezone
from gm_feed import DXYFeed, TickCursor, quote_valid
log = logging.getLogger("gm_micro")
W = {"EURUSD": -0.576, "USDJPY": 0.136, "GBPUSD": -0.119, "USDCAD": 0.091, "USDSEK": 0.042, "USDCHF": 0.036}
WIN = 3600                      # segundos guardados

def _tg(msg):
    tok, chat = os.getenv("TELEGRAM_TOKEN"), os.getenv("TELEGRAM_CHAT")
    if not (tok and chat): return
    try:
        import requests; requests.get(f"https://api.telegram.org/bot{tok}/sendMessage", params={"chat_id": chat, "text": msg}, timeout=5)
    except Exception: pass

class MicroMonitor:
    def __init__(self, gold, gm_dir):
        self.gold, self.dir = gold, gm_dir
        self.dxy_feed = DXYFeed(mt5)
        self.cursor = TickCursor()
        self._stop = threading.Event()
        self._thread = None
        self.last_cycle = time.time()
        self.pairs = {}
        for b in W:
            cands = [s.name for s in (mt5.symbols_get(f"*{b}*") or []) if s.name.startswith(b)]
            if cands: self.pairs[b] = sorted(cands, key=len)[0]; mt5.symbol_select(self.pairs[b], True)
        self.ts = collections.deque(maxlen=WIN); self.g = collections.deque(maxlen=WIN); self.d = collections.deque(maxlen=WIN)
        self.spr = collections.deque(maxlen=WIN); self.tps = collections.deque(maxlen=WIN); self.ofi = collections.deque(maxlen=WIN)
        self.state = {}; self._last_tick = None; self._last_alert = {}
        self.ok_dxy = bool(self.dxy_feed.direct) or all(self.dxy_feed.pairs.values())
        log.info(f"Micro: oro={gold} · pares DXY={list(self.pairs.values())}")

    def _dxy(self):
        q = self.dxy_feed.quote()
        return q.value if q.valid else np.nan

    def _gold_ticks(self):
        """OFI y nº de ticks del último segundo"""
        now = mt5.symbol_info_tick(self.gold)
        if not quote_valid(now): return None, 0, 0.0, 0.0
        wall = time.time()
        start = max(self.cursor.last_msc / 1000, wall - 10) if self.cursor.last_msc else wall - 1
        tk = mt5.copy_ticks_range(self.gold, datetime.fromtimestamp(start, timezone.utc),
                                 datetime.fromtimestamp(wall, timezone.utc), mt5.COPY_TICKS_INFO)
        ofi = 0.0; n = 0
        if tk is not None:
            for tick in self.cursor.take(tk):
                b, a = float(tick["bid"]), float(tick["ask"])
                if not (np.isfinite(b) and np.isfinite(a) and 0 < b <= a): continue
                n += 1
                if self._last_tick is not None:
                    ofi += np.sign(b-self._last_tick[0]) + np.sign(a-self._last_tick[1])
                self._last_tick = (b, a)
        return now, n, ofi, (now.ask - now.bid)

    @staticmethod
    def _z(x, n, times=None):
        x = np.asarray(x, float)
        if len(x) < n + 30: return 0.0
        t = np.asarray(times if times is not None else np.arange(len(x)), float)
        prior = np.searchsorted(t, t-n, side="right")-1
        ok = prior >= 0
        prior = np.maximum(prior, 0)
        ok &= (t-t[prior] <= n+2) & np.isfinite(x) & np.isfinite(x[prior])
        returns = x-x[prior]
        hist = returns[:-1][ok[:-1]]
        if not ok[-1] or len(hist) < 30: return 0.0
        sd = np.std(hist)
        return float((returns[-1]-hist.mean())/sd) if sd > 0 else 0.0

    def step(self):
        now, n, ofi, spread = self._gold_ticks()
        if now is None:
            self.state = {"micro_ts": int(time.time()), "market_valid": 0, "dxy_valid": 0,
                          "dxy_shock": 0, "micro_bias": 0, "status": "stale_quote"}
            return
        mid = (now.bid + now.ask)/2; dx = self._dxy() if self.ok_dxy else np.nan
        self.ts.append(time.time()); self.g.append(np.log(mid)); self.d.append(np.log(dx) if dx == dx else np.nan)
        self.spr.append(spread); self.tps.append(n); self.ofi.append(ofi)
        g = np.array(self.g); d = np.array(self.d)
        st = {"micro_ts": int(time.time()), "market_valid": 1, "dxy_valid": int(np.isfinite(dx)),
              "dxy_source": self.dxy_feed.direct or "synthetic_6_pairs", "gold_mid": round(mid, 5), "dxy_live": round(float(dx), 4) if dx == dx else 0,
              "g_z10": round(self._z(g, 10, self.ts), 2), "g_z60": round(self._z(g, 60, self.ts), 2),
              "tick_z": round(float((n - np.mean(self.tps))/(np.std(self.tps) or 1)), 2) if len(self.tps) > 60 else 0,
              "spread_z": round(float((spread - np.mean(self.spr))/(np.std(self.spr) or 1)), 2) if len(self.spr) > 60 else 0,
              "ofi_60": float(np.sum(list(self.ofi)[-60:]))}
        # micro-tendencia EWMA 5 s vs 60 s
        if len(g) > 60:
            e5 = np.average(g[-5:]); e60 = np.average(g[-60:]); st["micro_trend"] = round(float((e5-e60)*1e4), 2)
        # DXY
        if np.isfinite(dx) and np.isfinite(d).sum() > 120:
            st["dxy_z10"] = round(self._z(d, 10, self.ts), 2); st["dxy_z60"] = round(self._z(d, 60, self.ts), 2)
            m = ~np.isnan(d)
            if m.sum() > 400:
                # Preserve missing timestamps; never compress stale DXY periods.
                gr = np.diff(g[::5]); dr = np.diff(d[::5]); dt = np.diff(np.array(self.ts)[::5])
                good = np.isfinite(gr) & np.isfinite(dr) & (dt >= 4) & (dt <= 6)
                gr, dr = gr[good][-360:], dr[good][-360:]
                if len(gr) >= 60 and np.std(dr) > 0 and np.std(gr) > 0:
                    st["dxy_beta"] = round(float(np.cov(gr, dr)[0, 1]/np.var(dr, ddof=1)), 3)
                    st["dxy_corr_live"] = round(float(np.corrcoef(gr, dr)[0, 1]), 3)
                    # lead-lag (en pasos de 5 s): corr(dxy_t, oro_t+L)
                    best = (0, 0.0)
                    for L in (() if not good.all() else (1, 2, 3)):
                        c = np.corrcoef(dr[:-L], gr[L:])[0, 1]
                        if abs(c) > abs(best[1]): best = (L*5, c)
                    st["dxy_lead_s"], st["dxy_lead_corr"] = best[0], round(float(best[1]), 3)
                    past = np.searchsorted(np.array(self.ts), self.ts[-1]-60, side="right")-1
                    if past >= 0 and self.ts[-1]-self.ts[past] <= 62 and np.isfinite(d[past]):
                        st["gold_exp_move"] = round(float(st["dxy_beta"]*(d[-1]-d[past])*mid), 2)
            z = st["dxy_z60"]
            # An inverse gold/USD relation is not universal; require measured correlation.
            st["dxy_shock"] = int(np.sign(st.get("dxy_beta", 0)*z)) if abs(z)>2.5 and abs(st.get("dxy_corr_live", 0))>=.3 else 0
        # sesgo micro combinado (-1..1)
        dxy_term = st.get("dxy_shock", 0)
        mb = 0.4*np.tanh(st["g_z60"]/2) + 0.3*np.tanh(st["ofi_60"]/40) + 0.3*dxy_term
        st["micro_bias"] = round(float(np.clip(mb, -1, 1)), 3)
        self.state = st
        self._alerts(st)

    def _alerts(self, st):
        def fire(key, msg, cool=120):
            if time.time() - self._last_alert.get(key, 0) < cool: return
            self._last_alert[key] = time.time(); log.warning("ALERTA " + msg)
            with open(os.path.join(self.dir, "alerts.csv"), "a") as f: f.write(f"{int(time.time())},{key},{msg}\n")
        if st.get("dxy_shock"): fire("dxy", f"DXY SHOCK z60={st['dxy_z60']} → presión {'ALCISTA' if st['dxy_shock'] > 0 else 'BAJISTA'} en oro (esperado {st.get('gold_exp_move', 0)}$)")
        if abs(st["g_z10"]) > 3: fire("gold", f"Oro micro-movimiento brusco z10={st['g_z10']} OFI60={st['ofi_60']}", 60)
        if st.get("spread_z", 0) > 4: fire("spread", f"Spread anormal (z={st['spread_z']}) — evitar entradas", 300)

    def run(self):
        while not self._stop.is_set():
            t0 = time.time()
            try:
                self.step()
                with open(os.path.join(self.dir, "micro.tmp"), "w") as f: json.dump(self.state, f)
                for _ in range(5):                     # Windows: reintentar si el dashboard está leyendo el archivo
                    try: os.replace(os.path.join(self.dir, "micro.tmp"), os.path.join(self.dir, "micro.json")); break
                    except PermissionError: time.sleep(0.05)
            except Exception as ex:
                log.warning(f"micro: {ex}")
            self.last_cycle = time.time()
            self._stop.wait(max(0.05, 1 - (time.time() - t0)))

    def start(self):
        if self._thread is None or not self._thread.is_alive():
            self._stop.clear()
            self._thread = threading.Thread(target=self.run, daemon=True)
            self._thread.start()
        return self

    def stop(self):
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=2)
        return self._thread is None or not self._thread.is_alive()
