"""
ui/autotest.py — Prueba automática de la interfaz con datos REALES de MT5.

    .venv\\Scripts\\python.exe main.py --autotest logs\\captura.png --symbol XAUUSD

Pasos (cada uno se registra OK/FALLO en logs/autotest.log):
  conexión MT5 · carga de velas · replay (avance, retroceso, slider de velocidad,
  play) · operación SIMULADA con SL/TP · dibujo + edición · mercado sintético ·
  backtest · captura de pantalla de la ventana.
NUNCA envía órdenes reales (el trading real no se autoriza en ningún momento).
"""
from __future__ import annotations

import logging
import time
import traceback
from pathlib import Path

from PySide6 import QtCore, QtWidgets

log = logging.getLogger("ldz.autotest")


def _pump(app, ms: int = 200) -> None:
    end = time.time() + ms / 1000
    while time.time() < end:
        app.processEvents()
        time.sleep(0.01)


def run_autotest(app, w, out: Path, symbol: str) -> int:
    from core.app_state import app_state
    from mt5.connector import ConnectionState
    results = []
    for n in ("warning", "information", "critical"):
        setattr(QtWidgets.QMessageBox, n, staticmethod(lambda *a, **k: log.warning(f"diálogo: {a[1:3]}")))

    def step(name, fn):
        try:
            info = fn()
            results.append((True, name, info))
            log.info(f"[OK] {name}: {info}")
        except Exception as e:
            results.append((False, name, str(e)))
            log.error(f"[FALLO] {name}: {e}\n{traceback.format_exc()}")
        _pump(app, 150)

    _pump(app, 1500)
    step("MT5 conectado", lambda: (w.connector.state == ConnectionState.CONNECTED
                                    or (_ for _ in ()).throw(RuntimeError(w.connector.state.name)))
         and f"{w.connector.account.login}@{w.connector.account.server}")

    def load():
        w.src.setCurrentText("MT5")
        w.symbol.setCurrentText(symbol)
        w.base_tf.setCurrentText("M5")
        w.nbars.setValue(20000)
        w.chk_end.setChecked(False)
        w.chk_synth.setChecked(True)
        last = QtCore.QDateTime.currentDateTime().addDays(-4)
        w.start_dt.setDateTime(last)
        w._load()
        r = w.replay
        assert r is not None, "no se cargaron datos"
        return f"{len(r.bars)} velas M5, reloj {r.current_time:%Y-%m-%d %H:%M}"
    step("Carga de datos MT5 + SMC", load)

    def replay():
        r = w.replay
        i0 = r.idx
        for _ in range(30):
            w._next()
        w._prev()
        assert r.idx == i0 + 29
        w.replay_panel.set_speed_value(37)
        assert abs(r.speed - 37) < 0.01
        w._play(); _pump(app, 1500); w._pause()
        return f"avance/retroceso OK · slider {r.speed}x ({r.bars_per_tick()} velas/refresco) · idx {i0}→{r.idx}"
    step("Replay + slider de velocidad", replay)

    def order():
        w.trade_panel.sl_mode.setCurrentText("POINTS")
        w.trade_panel.sl.setValue(500)
        w.trade_panel.tp_mode.setCurrentText("R:R")
        w.trade_panel.tp.setValue(2)
        n = len(w.paper.trades)
        w._order("BUY", w.trade_panel.params())
        assert len(w.paper.trades) == n + 1, "no se abrió la operación simulada"
        t = w.paper.trades[-1]
        assert not app_state.real_trading_enabled
        for _ in range(60):
            w._next()
        return f"#{t.id} {t.volume} lotes @ {t.entry_price} SL {t.stop_loss} TP {t.take_profit} · estado {t.status}"
    step("Operación SIMULADA (sin MT5)", order)

    def drawing():
        ch = w.charts[3]
        df = ch.df
        w._save_drawing(ch, "trend", {"t1": df["time"].iloc[-80].isoformat(), "p1": float(df["low"].iloc[-80]),
                                      "t2": df["time"].iloc[-20].isoformat(), "p2": float(df["high"].iloc[-20])})
        w._save_drawing(ch, "fib", {"t1": df["time"].iloc[-120].isoformat(), "p1": float(df["high"].max()),
                                    "t2": df["time"].iloc[-60].isoformat(), "p2": float(df["low"].min())})
        _pump(app, 200)
        d = next(x for x in ch._drawings if x["kind"] == "trend")
        a2 = ch._to_px(*ch._anchors(d)[2])
        hit = ch.hit_test(a2)
        ch.begin_drag(hit, ch.plot.vb.mapSceneToView(a2))
        ch.update_drag(QtCore.QPointF(ch._anchors(d)[2][0] - 5, d["coordinates"]["p2"]))
        ch.finish_drag()
        return f"{len(ch._drawings)} dibujos · arrastre de ancla {hit}"
    step("Dibujos + edición por arrastre", drawing)

    def synthetic():
        w._jump(w.replay.bars[w.replay.n_real - 1].time)
        for _ in range(40):
            w._next()
        assert w.replay.in_synthetic_zone
        return f"{len(w.replay.bars) - w.replay.n_real} velas sintéticas · modo {w.mode.name}"
    step("Mercado sintético", synthetic)

    def backtest():
        w._run_backtest(w.bt_panel.params())
        w.pool.waitForDone(300_000)
        _pump(app, 500)
        assert w.bt_result is not None, "sin resultado"
        s = w.bt_result.statistics
        return f"{s['total_trades']} operaciones · neto {s['net_profit']} {s['currency']} · swap {s['swap_total']} ({s['swap_status']})"
    step("Backtest", backtest)

    def shot():
        w.resize(1600, 980)
        w.replay_panel.set_speed_value(5)
        _pump(app, 500)
        out.parent.mkdir(parents=True, exist_ok=True)
        assert w.grab().save(str(out)), "no se pudo guardar"
        return str(out)
    step("Captura de pantalla", shot)

    ok = sum(r[0] for r in results)
    summary = f"AUTOTEST: {ok}/{len(results)} pasos correctos"
    log.info(summary)
    with open(out.with_suffix(".txt"), "w", encoding="utf-8") as f:
        for r in results:
            f.write(f"{'OK   ' if r[0] else 'FALLO'} {r[1]}: {r[2]}\n")
        f.write(summary + "\n")
    w.close()
    return 0 if ok == len(results) else 1
