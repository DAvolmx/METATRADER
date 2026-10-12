"""
simular.py — Simulador de mercado SINTÉTICO (fin de semana / mercado cerrado)

1. Descarga las últimas velas reales de MT5 (o carga un CSV ya descargado).
2. Calibra el generador sintético con ese histórico.
3. Te deja operar en consola sobre velas futuras SIMULADAS.

Uso:
    python simular.py --symbol XAUUSD
    python simular.py --symbol XAUUSD --bars 30000 --seed 7 --vol 1.2
    python simular.py --csv data/history/XAUUSD_M1.csv      (sin MT5)

NUNCA envía órdenes reales: este script no importa el ejecutor real.
"""

from __future__ import annotations

import argparse
import logging
import sys
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).parent
(ROOT / "logs").mkdir(exist_ok=True)
logging.basicConfig(
    level=logging.WARNING,
    format="%(asctime)s | %(levelname)-8s | %(name)s | %(message)s",
    handlers=[logging.FileHandler(ROOT / "logs" / "sim.log", encoding="utf-8")],
)

from core.app_state import app_state, AppMode
from simulation.synthetic_market import (
    MarketCalibration, SimConfig, SyntheticMarket, SYNTHETIC_ENGINE_VERSION,
)
from simulation.sim_session import SimSession, SymbolSpec

HISTORY_DIR = ROOT / "data" / "history"

HELP = """
Comandos:
  n [k]              avanzar k velas (por defecto 1)
  b VOL [SL] [TP]    comprar   (ej: b 0.10 2310.5 2330)   usa 0 para omitir SL/TP
  s VOL [SL] [TP]    vender
  c [ID]             cerrar una operación (o todas)
  p                  posiciones abiertas
  h                  historial y estadísticas
  tf TF [k]          últimas k velas cerradas de TF (M1 M5 M15 H1 H4)
  ?                  ayuda
  q                  salir (exporta operaciones a CSV)
"""


def load_data(args):
    if args.csv:
        from mt5.market_data import load_history
        df, spec = load_history(Path(args.csv))
        print(f"  Histórico cargado de {args.csv}: {len(df)} velas")
        return df, spec

    from mt5.connector import MT5Connector, ConnectionState
    from mt5.market_data import fetch_rates, get_symbol_spec, save_history

    conn = MT5Connector()
    state, _ = conn.connect()
    if state != ConnectionState.CONNECTED:
        print("  No se pudo conectar a MT5. Abre MT5 o usa --csv con un histórico guardado.")
        sys.exit(1)
    try:
        print(f"  Descargando {args.bars} velas {args.timeframe} de {args.symbol} ...")
        df = fetch_rates(args.symbol, args.timeframe, args.bars)
        spec = get_symbol_spec(args.symbol)
        path = save_history(df, spec, HISTORY_DIR, args.timeframe)
        print(f"  {len(df)} velas guardadas en {path.relative_to(ROOT)}")
    finally:
        conn.disconnect()   # a partir de aquí MT5 no se usa
    return df, spec


def fmt_money(m):
    return "N/A" if m is None else f"{m:+.2f}"


def show_status(sess: SimSession, bar=None):
    if bar is not None:
        print(f"  {bar.time:%Y-%m-%d %H:%M}  O {bar.open}  H {bar.high}  "
              f"L {bar.low}  C {bar.close}")
    print(f"  [SIM] {sess.time:%Y-%m-%d %H:%M}  BID {sess.bid}  ASK {sess.ask}")
    for t in sess.open_trades:
        d = sess.floating(t)
        print(f"     #{t.id} {t.direction} {t.volume} @ {t.entry_price}  "
              f"SL {t.sl}  TP {t.tp}  flot: {sess.points(d):+} pts  {fmt_money(sess.money(t, d))}")


def report_closures(before: set, sess: SimSession):
    for t in sess.closed_trades:
        if t.id in before:
            d = t.price_diff(t.exit_price)
            print(f"  >>> #{t.id} cerrada por {t.exit_reason} @ {t.exit_price}  "
                  f"{sess.points(d):+} pts  {fmt_money(sess.money(t, d))}")


def opt_price(x):
    v = float(x)
    return None if v == 0 else v


def main() -> int:
    p = argparse.ArgumentParser(description="Simulador de mercado sintético LDZ")
    p.add_argument("--symbol", default="XAUUSD")
    p.add_argument("--timeframe", default="M1", choices=["M1", "M5", "M15"])
    p.add_argument("--bars", type=int, default=20000)
    p.add_argument("--csv", default=None, help="Usar histórico guardado (sin MT5)")
    p.add_argument("--seed", type=int, default=None)
    p.add_argument("--vol", type=float, default=1.0, help="Multiplicador de volatilidad")
    p.add_argument("--block", type=int, default=30, help="Velas por bloque remuestreado")
    p.add_argument("--keep-drift", action="store_true", help="Conservar la tendencia histórica")
    args = p.parse_args()

    app_state.mode = AppMode.SYNTHETIC
    print("=" * 64)
    print(f"  LDZ — SIMULACIÓN SINTÉTICA v{SYNTHETIC_ENGINE_VERSION}")
    print("  ⚠ DATOS NO REALES · NO ES UNA PREDICCIÓN · SIN ÓRDENES A MT5")
    print("=" * 64)

    df, spec_d = load_data(args)
    calib = MarketCalibration(df, args.timeframe, block_size=args.block)

    if spec_d:
        spec = SymbolSpec(**spec_d)
    else:
        spec = SymbolSpec(symbol=args.symbol, digits=calib.digits, point=10 ** -calib.digits)
        print("  (sin metadatos del símbolo: P&L en dinero = N/A)")

    seed = args.seed if args.seed is not None else int(datetime.now().timestamp())
    cfg = SimConfig(
        timeframe=args.timeframe, block_size=args.block, vol_multiplier=args.vol,
        remove_drift=not args.keep_drift, seed=seed, digits=spec.digits,
    )
    sess = SimSession(SyntheticMarket(calib, cfg), spec)

    print(f"  Último dato real: {calib.last_time:%Y-%m-%d %H:%M}  cierre {calib.last_close}")
    print(f"  Semilla: {seed}  (repite el mismo escenario con --seed {seed})")
    print(HELP)
    show_status(sess)

    while True:
        try:
            raw = input("sim> ").strip().split()
        except (EOFError, KeyboardInterrupt):
            raw = ["q"]
        if not raw:
            raw = ["n"]
        cmd, a = raw[0].lower(), raw[1:]
        try:
            if cmd == "n":
                k = int(a[0]) if a else 1
                bar = None
                for _ in range(k):
                    open_ids = {t.id for t in sess.open_trades}
                    bar = sess.next_bar()
                    report_closures(open_ids, sess)
                show_status(sess, bar)
            elif cmd in ("b", "s"):
                vol = float(a[0])
                sl = opt_price(a[1]) if len(a) > 1 else None
                tp = opt_price(a[2]) if len(a) > 2 else None
                t = sess.open_trade("BUY" if cmd == "b" else "SELL", vol, sl, tp)
                print(f"  Abierta #{t.id} {t.direction} {t.volume} @ {t.entry_price}")
            elif cmd == "c":
                for t in sess.close_trade(int(a[0]) if a else None):
                    d = t.price_diff(t.exit_price)
                    print(f"  Cerrada #{t.id} @ {t.exit_price}  {sess.points(d):+} pts  "
                          f"{fmt_money(sess.money(t, d))}")
            elif cmd == "p":
                show_status(sess)
            elif cmd == "h":
                for t in sess.closed_trades:
                    d = t.price_diff(t.exit_price)
                    print(f"  #{t.id} {t.direction} {t.volume} {t.entry_price}→{t.exit_price} "
                          f"{t.exit_reason}  {sess.points(d):+} pts  {fmt_money(sess.money(t, d))}")
                print(f"  {sess.stats()}")
            elif cmd == "tf":
                tf = a[0].upper()
                k = int(a[1]) if len(a) > 1 else 5
                bars = sess.base_bars if tf == args.timeframe else sess.aggregators[tf].closed
                for b in bars[-k:]:
                    print(f"  {tf} {b.time:%Y-%m-%d %H:%M}  O {b.open} H {b.high} L {b.low} C {b.close}")
                if not bars:
                    print("  (aún no hay velas cerradas en esa temporalidad)")
            elif cmd == "?":
                print(HELP)
            elif cmd == "q":
                if sess.trades:
                    out = ROOT / "data" / f"sim_trades_{datetime.now():%Y%m%d_%H%M%S}.csv"
                    sess.export_trades_csv(out)
                    print(f"  Operaciones exportadas a {out.relative_to(ROOT)}")
                print(f"  {sess.stats()}")
                return 0
            else:
                print("  Comando desconocido. Escribe ? para ayuda.")
        except (ValueError, IndexError, KeyError) as e:
            print(f"  Error: {e}")


if __name__ == "__main__":
    sys.exit(main())
