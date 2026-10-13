"""
gm_bridge.py — Lado Python del PUENTE ML EA⇄Python (cierra el "ddl"/bridge).

Contrato EXACTO con Include/GoldMaster/GoldMaster_ML.mqh (clase CGMLBridge):

  EA  -> escribe  Common\\Files\\GoldMaster\\ml_features.csv
         cabecera: timestamp,symbol,close,atr,ema21,ema50,ema200,trend,dxy_bias,session,confluence
  Py  -> escribe  Common\\Files\\GoldMaster\\ml_predictions.csv
         cabecera: timestamp,signal,confidence_lstm,confidence_xgb,confidence_lgbm,
                   ensemble_signal,ensemble_confidence,price_target,regime
         timestamp en formato MT5  'YYYY.MM.DD HH:MM:SS'  (StringToTime del EA)

Es un puente de FICHEROS (lo que ya usa el sistema vía Common\\Files): no hace falta
compilar ninguna DLL de C++ ni abrir puertos; funciona en el tester y en vivo, y no
toca credenciales del broker. El EA mantiene la decisión final; esto solo informa.

Tres clasificadores reales entrenados sobre los datos del usuario pueblan las tres
columnas de confianza (mapa honesto):
    confidence_lstm <- Regresión logística     confidence_xgb <- HistGradientBoosting
    confidence_lgbm <- RandomForest            ensemble        <- media de las tres
El régimen sale del HMM de gm_ml. El modelo se entrena con EXACTAMENTE las mismas
features que el EA envía por fila, así que entrenar y predecir son idénticos.

Uso:
    python gm_bridge.py train  <XAUUSD_M1.csv> [--horizon 16] [--thr 0.0015]
    python gm_bridge.py predict <XAUUSD_M1.csv>         # demo: features de la última vela
    python gm_bridge.py serve  [--dir <GoldMaster>] [--interval 5]   # loop EA<->Py
"""
from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

import numpy as np
import pandas as pd

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "optimizer"))
sys.path.insert(0, str(HERE))

from mt5_import import load_mt5, resample     # noqa: E402

MODEL_PATH = HERE / "out_offline" / "bridge_model.joblib"
MT5_TS = "%Y.%m.%d %H:%M:%S"
PRED_HEADER = ("timestamp,signal,confidence_lstm,confidence_xgb,confidence_lgbm,"
               "ensemble_signal,ensemble_confidence,price_target,regime")
FEAT_COLS = ["close", "atr", "ema21", "ema50", "ema200", "trend", "dxy_bias", "session", "confluence"]


# ───────────────────────── features (idénticas en train y serve) ─────────────────────────
def feat_from_row(row: dict) -> list[float]:
    """Deriva features ESCALA-INVARIANTE desde una fila con las columnas del EA.

    Todo es computable con una sola vela, así el servidor en vivo (que recibe una
    fila del EA) y el entrenamiento (una fila por vela) usan la misma función.
    """
    close = float(row["close"]); atr = max(float(row.get("atr", 0.0)), 1e-9)
    e21, e50, e200 = float(row["ema21"]), float(row["ema50"]), float(row["ema200"])
    trend = float(row.get("trend", 0.0))
    dxy = float(row.get("dxy_bias", 0.0)); conf = float(row.get("confluence", 0.0))
    sess = float(row.get("session", 0.0))
    return [
        atr / close * 1e4,            # ATR en puntos básicos
        (close - e21) / atr,          # distancia a EMA21 en ATR
        (e21 - e50) / atr,            # pendiente rápida/lenta
        (e50 - e200) / atr,           # tendencia estructural
        trend, dxy, conf,
        np.sin(2 * np.pi * sess / 3), np.cos(2 * np.pi * sess / 3),  # sesión cíclica
    ]


FEATN = len(feat_from_row(dict(close=1, atr=1, ema21=1, ema50=1, ema200=1, trend=0,
                               dxy_bias=0, session=0, confluence=0)))


def _ema(x, n): return pd.Series(x).ewm(span=n, adjust=False).mean().to_numpy()


def _atr(h, l, c, n=14):
    pc = np.r_[c[0], c[:-1]]
    tr = np.maximum(h - l, np.maximum(np.abs(h - pc), np.abs(l - pc)))
    return pd.Series(tr).ewm(alpha=1 / n, adjust=False).mean().to_numpy()


def build_training(m15: pd.DataFrame, horizon: int, thr: float):
    """Construye (X, y) desde M15, con las MISMAS features que envía el EA.

    Etiqueta: dirección del retorno a `horizon` velas (>+thr => sube, <-thr => baja);
    las neutrales se descartan. dxy_bias/confluence no son observables offline → 0,
    igual que una sesión sin esos módulos; cuando el EA los manda en vivo, entran.
    """
    c = m15["close"].to_numpy(float); h = m15["high"].to_numpy(float); l = m15["low"].to_numpy(float)
    atr = _atr(h, l, c); e21 = _ema(c, 21); e50 = _ema(c, 50); e200 = _ema(c, 200)
    hour = pd.to_datetime(m15["time"]).dt.hour.to_numpy()
    session = np.where(hour < 7, 0, np.where(hour < 13, 1, 2))      # asia/londres/ny
    trend = np.sign(e21 - e50) + np.sign(e50 - e200)               # -2..+2 → signo
    trend = np.sign(trend)
    n = len(c)
    X, y = [], []
    for i in range(200, n - horizon):
        ret = c[i + horizon] / c[i] - 1
        label = 1 if ret > thr else (0 if ret < -thr else -1)
        if label < 0:
            continue
        row = dict(close=c[i], atr=atr[i], ema21=e21[i], ema50=e50[i], ema200=e200[i],
                   trend=trend[i], dxy_bias=0.0, session=session[i], confluence=0.0)
        X.append(feat_from_row(row)); y.append(label)
    return np.array(X, float), np.array(y, int)


# ───────────────────────── entrenamiento ─────────────────────────
def train(csv_path: str, horizon: int = 16, thr: float = 0.0015, train_frac: float = 0.70):
    from sklearn.ensemble import HistGradientBoostingClassifier, RandomForestClassifier
    from sklearn.linear_model import LogisticRegression
    from sklearn.preprocessing import StandardScaler
    from sklearn.metrics import roc_auc_score
    import joblib

    m1 = load_mt5(csv_path); m15 = resample(m1, "M15")
    X, y = build_training(m15, horizon, thr)
    if len(X) < 200 or len(np.unique(y)) < 2:
        return {"error": f"datos insuficientes para entrenar (muestras={len(X)})"}
    split = int(len(X) * train_frac)
    Xtr, Xte, ytr, yte = X[:split], X[split:], y[:split], y[split:]

    sc = StandardScaler().fit(Xtr)
    lr = LogisticRegression(C=0.5, max_iter=2000).fit(sc.transform(Xtr), ytr)
    gb = HistGradientBoostingClassifier(max_depth=3, learning_rate=0.05, max_iter=300,
                                        l2_regularization=1.0, random_state=1).fit(Xtr, ytr)
    rf = RandomForestClassifier(n_estimators=250, max_depth=6, min_samples_leaf=20,
                                random_state=1, n_jobs=-1).fit(Xtr, ytr)

    def auc(model, scale=False):
        p = model.predict_proba(sc.transform(Xte) if scale else Xte)[:, 1]
        return float(roc_auc_score(yte, p)) if len(np.unique(yte)) > 1 else None

    bundle = dict(scaler=sc, lr=lr, gb=gb, rf=rf, featn=FEATN, horizon=horizon, thr=thr,
                  research_only=True, trained_on=Path(csv_path).name)
    MODEL_PATH.parent.mkdir(exist_ok=True)
    joblib.dump(bundle, MODEL_PATH)
    return dict(samples=int(len(X)), train=int(split), test=int(len(X) - split),
                pos_rate=float(y.mean()), horizon=horizon, thr=thr,
                auc_oos=dict(logistic=auc(lr, True), gb=auc(gb), rf=auc(rf)),
                model=str(MODEL_PATH.name), status="research_only")


# ───────────────────────── predicción ─────────────────────────
def _load_bundle():
    import joblib
    if not MODEL_PATH.exists():
        raise FileNotFoundError("No hay modelo entrenado. Ejecuta: python gm_bridge.py train <csv>")
    return joblib.load(MODEL_PATH)


def predict_row(row: dict, bundle=None, regime: str = "unknown", min_conf: float = 0.60) -> dict:
    """Puntúa una fila de features del EA y devuelve el dict de predicción."""
    b = bundle or _load_bundle()
    x = np.array([feat_from_row(row)], float)
    x = np.nan_to_num(x, nan=0.0, posinf=0.0, neginf=0.0)
    p_lr = float(b["lr"].predict_proba(b["scaler"].transform(x))[0, 1])
    p_gb = float(b["gb"].predict_proba(x)[0, 1])
    p_rf = float(b["rf"].predict_proba(x)[0, 1])
    ens = (p_lr + p_gb + p_rf) / 3.0
    conf = max(ens, 1.0 - ens)
    signal = 1 if ens >= min_conf else (-1 if ens <= 1 - min_conf else 0)
    return dict(signal=signal, conf_lstm=p_lr, conf_xgb=p_gb, conf_lgbm=p_rf,
                ensemble_signal=signal, ensemble_conf=conf, regime=regime)


def _fmt_pred_line(ts: pd.Timestamp, p: dict, price_target: float) -> str:
    return (f"{ts.strftime(MT5_TS)},{p['signal']},{p['conf_lstm']:.4f},{p['conf_xgb']:.4f},"
            f"{p['conf_lgbm']:.4f},{p['ensemble_signal']},{p['ensemble_conf']:.4f},"
            f"{price_target:.2f},{p['regime']}")


def write_predictions(path: Path, ts: pd.Timestamp, p: dict, price_target: float):
    """Escritura atómica (tmp+replace) para que el EA nunca lea un fichero a medias."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(PRED_HEADER + "\n" + _fmt_pred_line(ts, p, price_target) + "\n", encoding="ascii")
    tmp.replace(path)


def read_features(path: Path) -> dict | None:
    try:
        df = pd.read_csv(path)
    except Exception:
        return None
    if df.empty:
        return None
    row = df.iloc[-1].to_dict()
    low = {str(k).strip().lower(): v for k, v in row.items()}
    if "close" not in low or "ema21" not in low:
        return None
    return low


# ───────────────────────── loop EA ⇄ Py ─────────────────────────
def serve(bridge_dir: str, interval: float = 5.0, min_conf: float = 0.60, once: bool = False):
    d = Path(bridge_dir)
    feat_path, pred_path = d / "ml_features.csv", d / "ml_predictions.csv"
    bundle = _load_bundle()
    print(f"[bridge] sirviendo {feat_path}  ->  {pred_path}  (Ctrl+C para parar)", flush=True)
    last_sig = None
    while True:
        row = read_features(feat_path)
        if row is not None:
            try:
                p = predict_row(row, bundle, regime=str(row.get("regime", "unknown")), min_conf=min_conf)
                ts = pd.Timestamp.now(tz="UTC").tz_localize(None)
                write_predictions(pred_path, ts, p, float(row.get("close", 0.0)))
                if p["signal"] != last_sig:
                    print(f"[bridge] {ts.strftime(MT5_TS)} signal={p['signal']:+d} "
                          f"conf={p['ensemble_conf']:.2f}", flush=True)
                    last_sig = p["signal"]
            except Exception as e:
                print(f"[bridge] error al predecir: {e}", flush=True)
        if once:
            return
        time.sleep(interval)


# ───────────────────────── CLI ─────────────────────────
def main(argv=None):
    ap = argparse.ArgumentParser(description="Puente ML EA<->Python (bridge de ficheros)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    pt = sub.add_parser("train"); pt.add_argument("csv"); pt.add_argument("--horizon", type=int, default=16)
    pt.add_argument("--thr", type=float, default=0.0015)
    pp = sub.add_parser("predict"); pp.add_argument("csv")
    ps = sub.add_parser("serve"); ps.add_argument("--dir", default="GoldMaster")
    ps.add_argument("--interval", type=float, default=5.0); ps.add_argument("--min-conf", type=float, default=0.60)
    a = ap.parse_args(argv)

    if a.cmd == "train":
        import json
        print(json.dumps(train(a.csv, a.horizon, a.thr), indent=2, ensure_ascii=False))
    elif a.cmd == "predict":
        m1 = load_mt5(a.csv); m15 = resample(m1, "M15")
        c = m15["close"].to_numpy(float); h = m15["high"].to_numpy(float); l = m15["low"].to_numpy(float)
        atr = _atr(h, l, c); e21 = _ema(c, 21); e50 = _ema(c, 50); e200 = _ema(c, 200)
        hour = pd.to_datetime(m15["time"]).dt.hour.to_numpy()[-1]
        trend = float(np.sign(np.sign(e21[-1] - e50[-1]) + np.sign(e50[-1] - e200[-1])))
        row = dict(close=c[-1], atr=atr[-1], ema21=e21[-1], ema50=e50[-1], ema200=e200[-1],
                   trend=trend, dxy_bias=0.0, session=(0 if hour < 7 else 1 if hour < 13 else 2),
                   confluence=0.0)
        p = predict_row(row)
        import json
        print("features EA (última vela M15):", {k: round(float(v), 2) for k, v in row.items()})
        print(json.dumps(p, indent=2, ensure_ascii=False))
    elif a.cmd == "serve":
        serve(a.dir, a.interval, a.min_conf)


if __name__ == "__main__":
    main()
