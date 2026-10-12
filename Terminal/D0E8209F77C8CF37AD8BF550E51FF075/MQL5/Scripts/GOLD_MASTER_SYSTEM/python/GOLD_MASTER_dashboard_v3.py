#!/usr/bin/env python3
"""
GOLD MASTER SYSTEM — Dashboard v3.1
Ensemble ML (LSTM + XGBoost + LightGBM) + Telegram alerts
+ Equity curve + Session heatmap + Sharpe/Drawdown + Backtesting visual
"""

import os
import MetaTrader5 as mt5
import pandas as pd
import numpy as np
import datetime, time, os, csv, json, threading, warnings, logging

warnings.filterwarnings("ignore")
logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger("GoldMaster")

import dash
from dash import dcc, html, Input, Output, State, callback_context
import plotly.graph_objects as go
from plotly.subplots import make_subplots
import dash_bootstrap_components as dbc

# ML
from sklearn.preprocessing import MinMaxScaler
from sklearn.metrics import accuracy_score
import tensorflow as tf
from tensorflow.keras.models import Sequential
from tensorflow.keras.layers import LSTM, Dense, Dropout, BatchNormalization
from tensorflow.keras.callbacks import EarlyStopping

try:
    import xgboost as xgb
    HAS_XGB = True
except ImportError:
    HAS_XGB = False
    log.warning("XGBoost no disponible, usando solo LSTM")

try:
    import lightgbm as lgb
    HAS_LGB = True
except ImportError:
    HAS_LGB = False
    log.warning("LightGBM no disponible, usando solo LSTM")

try:
    import requests
    HAS_REQUESTS = True
except ImportError:
    HAS_REQUESTS = False

# ════════════════════════════════════════════════════════
#  CONFIGURACIÓN
# ════════════════════════════════════════════════════════
def _resolve_symbol():
    """GM_SYMBOL (ej. XAUUSDmicro) o auto-detección del primer símbolo de oro del broker."""
    want = os.environ.get("GM_SYMBOL", "XAUUSD")
    if not mt5.initialize():
        return want
    if mt5.symbol_info(want) is None:
        cands = [x.name for x in (mt5.symbols_get("*XAU*") or [])]
        if cands:
            log.warning(f"{want} no existe; usando {cands[0]} (disponibles: {cands})")
            want = cands[0]
    mt5.symbol_select(want, True)
    si = mt5.symbol_info(want)
    if si:
        log.info(f"{want}: lote min {si.volume_min} · step {si.volume_step} · contrato {si.trade_contract_size}")
    return want

SYMBOL       = _resolve_symbol()
_si = mt5.symbol_info(SYMBOL)
MIN_LOT  = _si.volume_min  if _si else 0.01
LOT_STEP = _si.volume_step if _si else 0.01
TIMEFRAME    = mt5.TIMEFRAME_M15
BARS         = 2000
LOOKBACK     = 60          # ventana LSTM
RETRAIN_HRS  = 6           # horas entre reentrenamientos
CSV_DIR      = os.path.join(os.environ.get("APPDATA",""), "MetaQuotes", "Terminal",
               "Common", "Files", "GoldMaster")

TELEGRAM_TOKEN = os.environ.get("GM_TELEGRAM_TOKEN", "")
TELEGRAM_CHAT  = os.environ.get("GM_TELEGRAM_CHAT", "")

# ════════════════════════════════════════════════════════
#  MANAGER MT5
# ════════════════════════════════════════════════════════
class MT5Manager:
    def __init__(self):
        self.connected = False

    def connect(self):
        if not mt5.initialize():
            log.error(f"MT5 init falló: {mt5.last_error()}")
            return False
        self.connected = True
        log.info(f"MT5 conectado | cuenta: {mt5.account_info().login}")
        return True

    def get_bars(self, symbol=SYMBOL, tf=TIMEFRAME, n=BARS):
        rates = mt5.copy_rates_from_pos(symbol, tf, 0, n)
        if rates is None or len(rates) == 0:
            return pd.DataFrame()
        df = pd.DataFrame(rates)
        df["time"] = pd.to_datetime(df["time"], unit="s")
        df.set_index("time", inplace=True)
        return df

    def get_account(self):
        info = mt5.account_info()
        if info is None:
            return {}
        return {
            "balance":   info.balance,
            "equity":    info.equity,
            "margin":    info.margin,
            "free":      info.margin_free,
            "profit":    info.profit,
            "leverage":  info.leverage,
        }

    def get_positions(self):
        pos = mt5.positions_get(symbol=SYMBOL)
        if pos is None:
            return []
        return [{"ticket": p.ticket, "type": "BUY" if p.type==0 else "SELL",
                 "lot": p.volume, "open": p.price_open, "sl": p.sl,
                 "tp": p.tp, "profit": p.profit, "time": p.time} for p in pos]

    def get_pending(self):
        orders = mt5.orders_get(symbol=SYMBOL)
        if orders is None:
            return []
        type_map = {0:"BuyLimit",1:"SellLimit",2:"BuyStop",3:"SellStop"}
        return [{"ticket": o.ticket, "type": type_map.get(o.type,"?"),
                 "lot": o.volume_initial, "price": o.price_open,
                 "sl": o.sl, "tp": o.tp, "expiry": o.time_expiration} for o in orders]

    def get_deals(self, days=30):
        from_dt = datetime.datetime.now() - datetime.timedelta(days=days)
        deals = mt5.history_deals_get(from_dt, datetime.datetime.now())
        if deals is None:
            return pd.DataFrame()
        df = pd.DataFrame(list(deals), columns=deals[0]._asdict().keys())
        df["time"] = pd.to_datetime(df["time"], unit="s")
        return df

    def place_order(self, action, symbol, lot, sl, tp, comment="GM"):
        price = mt5.symbol_info_tick(symbol).ask if action=="BUY" else mt5.symbol_info_tick(symbol).bid
        req = {
            "action": mt5.TRADE_ACTION_DEAL,
            "symbol": symbol,
            "volume": lot,
            "type": mt5.ORDER_TYPE_BUY if action=="BUY" else mt5.ORDER_TYPE_SELL,
            "price": price,
            "sl": sl, "tp": tp,
            "deviation": 10,
            "magic": 900000,
            "comment": comment,
            "type_time": mt5.ORDER_TIME_GTC,
            "type_filling": mt5.ORDER_FILLING_IOC,
        }
        result = mt5.order_send(req)
        return result

    def close_position(self, ticket):
        pos = mt5.positions_get(ticket=ticket)
        if pos:
            p = pos[0]
            price = mt5.symbol_info_tick(p.symbol).bid if p.type==0 else mt5.symbol_info_tick(p.symbol).ask
            req = {
                "action": mt5.TRADE_ACTION_DEAL, "symbol": p.symbol,
                "volume": p.volume,
                "type": mt5.ORDER_TYPE_SELL if p.type==0 else mt5.ORDER_TYPE_BUY,
                "position": ticket, "price": price, "deviation": 10,
                "magic": 900000, "comment": "GM_CLOSE",
                "type_time": mt5.ORDER_TIME_GTC,
                "type_filling": mt5.ORDER_FILLING_IOC,
            }
            return mt5.order_send(req)

    def cancel_order(self, ticket):
        req = {"action": mt5.TRADE_ACTION_REMOVE, "order": ticket}
        return mt5.order_send(req)

# ════════════════════════════════════════════════════════
#  SMC ENGINE (análisis técnico básico para dashboard)
# ════════════════════════════════════════════════════════
class SMCEngine:
    def get_structure(self, df, n=50):
        """Retorna swings highs/lows para visualización"""
        highs, lows = [], []
        for i in range(2, min(n, len(df)-2)):
            h = df["high"].iloc[-i]
            l = df["low"].iloc[-i]
            t = df.index[-i]
            if df["high"].iloc[-i] > df["high"].iloc[-i-1] and df["high"].iloc[-i] > df["high"].iloc[-i+1]:
                highs.append((t, h))
            if df["low"].iloc[-i] < df["low"].iloc[-i-1] and df["low"].iloc[-i] < df["low"].iloc[-i+1]:
                lows.append((t, l))
        return highs, lows

    def get_fvgs(self, df, n=50):
        fvgs = []
        for i in range(2, min(n, len(df)-1)):
            prev = df.iloc[-i-1]
            cur  = df.iloc[-i]
            next_ = df.iloc[-i+1]
            if next_["low"] > prev["high"]:
                fvgs.append({"type":"bull", "top": next_["low"], "bot": prev["high"], "time": cur.name})
            elif next_["high"] < prev["low"]:
                fvgs.append({"type":"bear", "top": prev["low"],  "bot": next_["high"], "time": cur.name})
        return fvgs

    def get_obs(self, df, n=30):
        obs = []
        atr = df["close"].diff().abs().rolling(14).mean().iloc[-1]
        for i in range(2, min(n, len(df)-2)):
            c  = df.iloc[-i]
            n_ = df.iloc[-i-1]
            body = abs(c["close"] - c["open"])
            if body < atr * 0.5: continue
            if c["close"] > c["open"] and n_["close"] < n_["open"]:
                obs.append({"type":"bull","top":c["high"],"bot":c["low"],"time":c.name})
            elif c["close"] < c["open"] and n_["close"] > n_["open"]:
                obs.append({"type":"bear","top":c["high"],"bot":c["low"],"time":c.name})
        return obs[:5]

    def get_equilibrium(self, df, n=50):
        if len(df) < n: return df["close"].mean()
        hi = df["high"].iloc[-n:].max()
        lo = df["low"].iloc[-n:].min()
        return (hi + lo) / 2

# ════════════════════════════════════════════════════════
#  FEATURE ENGINEERING
# ════════════════════════════════════════════════════════
def build_features(df):
    d = df.copy()
    d["atr"]     = (d["high"] - d["low"]).rolling(14).mean()
    d["ema21"]   = d["close"].ewm(span=21).mean()
    d["ema50"]   = d["close"].ewm(span=50).mean()
    d["ema200"]  = d["close"].ewm(span=200).mean()
    d["rsi"]     = compute_rsi(d["close"], 14)
    d["volume_z"]= (d["tick_volume"] - d["tick_volume"].rolling(20).mean()) / \
                   (d["tick_volume"].rolling(20).std() + 1e-9)
    d["macd"]    = d["close"].ewm(span=12).mean() - d["close"].ewm(span=26).mean()
    d["bb_width"]= (d["close"].rolling(20).std() * 2) / (d["close"].rolling(20).mean() + 1e-9)
    d["body"]    = abs(d["close"] - d["open"]) / (d["atr"] + 1e-9)
    d["trend21"] = (d["close"] > d["ema21"]).astype(int) * 2 - 1
    d["trend50"] = (d["close"] > d["ema50"]).astype(int) * 2 - 1
    d["hour"]    = d.index.hour
    d["dow"]     = d.index.dayofweek
    d.dropna(inplace=True)
    return d

def compute_rsi(series, period=14):
    delta = series.diff()
    gain  = delta.clip(lower=0).rolling(period).mean()
    loss  = (-delta.clip(upper=0)).rolling(period).mean()
    rs    = gain / (loss + 1e-9)
    return 100 - 100 / (1 + rs)

FEATURE_COLS = ["atr","ema21","ema50","ema200","rsi","volume_z","macd","bb_width",
                "body","trend21","trend50","hour","dow"]

def make_labels(df, horizon=4):
    future = df["close"].shift(-horizon)
    ret    = (future - df["close"]) / df["close"]
    labels = np.where(ret > 0.0005, 1, np.where(ret < -0.0005, -1, 0))
    return labels

# ════════════════════════════════════════════════════════
#  LSTM MODEL
# ════════════════════════════════════════════════════════
class LSTMModel:
    def __init__(self, lookback=LOOKBACK):
        self.lookback = lookback
        self.scaler   = MinMaxScaler()
        self.model    = None
        self.trained  = False

    def build(self, n_features):
        m = Sequential([
            LSTM(128, return_sequences=True, input_shape=(self.lookback, n_features)),
            BatchNormalization(),
            Dropout(0.2),
            LSTM(64, return_sequences=False),
            BatchNormalization(),
            Dropout(0.2),
            Dense(32, activation="relu"),
            Dense(3, activation="softmax"),   # [sell, neutral, buy]
        ])
        m.compile(optimizer="adam", loss="sparse_categorical_crossentropy", metrics=["accuracy"])
        self.model = m

    def train(self, df):
        feat_df = build_features(df)
        if len(feat_df) < self.lookback + 50:
            return 0.0
        X_raw = feat_df[FEATURE_COLS].values
        y_raw = make_labels(feat_df) + 1   # -1→0, 0→1, 1→2
        X_sc  = self.scaler.fit_transform(X_raw)
        X_seq, y_seq = [], []
        for i in range(self.lookback, len(X_sc) - 4):
            X_seq.append(X_sc[i-self.lookback:i])
            y_seq.append(y_raw[i])
        X_seq, y_seq = np.array(X_seq), np.array(y_seq)
        split = int(len(X_seq) * 0.8)
        X_train, X_val = X_seq[:split], X_seq[split:]
        y_train, y_val = y_seq[:split], y_seq[split:]
        if self.model is None:
            self.build(X_train.shape[2])
        self.model.fit(X_train, y_train,
                       validation_data=(X_val, y_val),
                       epochs=20, batch_size=32,
                       callbacks=[EarlyStopping(patience=3, restore_best_weights=True)],
                       verbose=0)
        preds = np.argmax(self.model.predict(X_val, verbose=0), axis=1)
        acc   = accuracy_score(y_val, preds)
        self.trained = True
        log.info(f"LSTM entrenado | acc: {acc:.2%}")
        return acc

    def predict_proba(self, df):
        if not self.trained or self.model is None:
            return None, 0.0
        feat_df = build_features(df)
        if len(feat_df) < self.lookback:
            return None, 0.0
        X_raw = feat_df[FEATURE_COLS].values[-self.lookback:]
        X_sc  = self.scaler.transform(X_raw)
        X_inp = X_sc.reshape(1, self.lookback, -1)
        proba = self.model.predict(X_inp, verbose=0)[0]
        signal_idx = np.argmax(proba)
        signal = signal_idx - 1  # 0→-1, 1→0, 2→1
        conf   = float(proba[signal_idx])
        return signal, conf

# ════════════════════════════════════════════════════════
#  XGBOOST / LIGHTGBM MODELS
# ════════════════════════════════════════════════════════
class XGBModel:
    def __init__(self):
        self.model   = None
        self.scaler  = MinMaxScaler()
        self.trained = False

    def train(self, df):
        if not HAS_XGB: return 0.0
        feat_df = build_features(df)
        if len(feat_df) < 100: return 0.0
        X = self.scaler.fit_transform(feat_df[FEATURE_COLS].values[:-4])
        y = (make_labels(feat_df) + 1)[:-4]
        split = int(len(X) * 0.8)
        self.model = xgb.XGBClassifier(n_estimators=200, max_depth=5, learning_rate=0.05,
                                        use_label_encoder=False, eval_metric="mlogloss",
                                        verbosity=0)
        self.model.fit(X[:split], y[:split])
        preds = self.model.predict(X[split:])
        acc   = accuracy_score(y[split:], preds)
        self.trained = True
        log.info(f"XGBoost entrenado | acc: {acc:.2%}")
        return acc

    def predict_proba(self, df):
        if not HAS_XGB or not self.trained: return None, 0.0
        feat_df = build_features(df)
        if len(feat_df) < 5: return None, 0.0
        X = self.scaler.transform(feat_df[FEATURE_COLS].values[-1:])
        proba = self.model.predict_proba(X)[0]
        signal_idx = np.argmax(proba)
        return signal_idx - 1, float(proba[signal_idx])

class LGBMModel:
    def __init__(self):
        self.model   = None
        self.scaler  = MinMaxScaler()
        self.trained = False

    def train(self, df):
        if not HAS_LGB: return 0.0
        feat_df = build_features(df)
        if len(feat_df) < 100: return 0.0
        X = self.scaler.fit_transform(feat_df[FEATURE_COLS].values[:-4])
        y = (make_labels(feat_df) + 1)[:-4]
        split = int(len(X) * 0.8)
        self.model = lgb.LGBMClassifier(n_estimators=200, max_depth=5, learning_rate=0.05,
                                         verbose=-1)
        self.model.fit(X[:split], y[:split])
        preds = self.model.predict(X[split:])
        acc   = accuracy_score(y[split:], preds)
        self.trained = True
        log.info(f"LightGBM entrenado | acc: {acc:.2%}")
        return acc

    def predict_proba(self, df):
        if not HAS_LGB or not self.trained: return None, 0.0
        feat_df = build_features(df)
        if len(feat_df) < 5: return None, 0.0
        X = self.scaler.transform(feat_df[FEATURE_COLS].values[-1:])
        proba = self.model.predict_proba(X)[0]
        signal_idx = np.argmax(proba)
        return signal_idx - 1, float(proba[signal_idx])

# ════════════════════════════════════════════════════════
#  ENSEMBLE ENGINE
# ════════════════════════════════════════════════════════
class EnsembleEngine:
    def __init__(self):
        self.lstm  = LSTMModel(LOOKBACK)
        self.xgb   = XGBModel()
        self.lgbm  = LGBMModel()
        self.last_train = None
        self.weights = {"lstm": 0.4, "xgb": 0.3, "lgbm": 0.3}

    def train_all(self, df):
        log.info("Entrenando ensemble completo...")
        self.lstm.train(df)
        self.xgb.train(df)
        self.lgbm.train(df)
        self.last_train = datetime.datetime.now()
        log.info("Ensemble entrenado.")

    def needs_retrain(self):
        if self.last_train is None: return True
        hours = (datetime.datetime.now() - self.last_train).seconds / 3600
        return hours >= RETRAIN_HRS

    def predict(self, df):
        lstm_sig,  lstm_conf  = self.lstm.predict_proba(df)
        xgb_sig,   xgb_conf   = self.xgb.predict_proba(df)
        lgbm_sig,  lgbm_conf  = self.lgbm.predict_proba(df)

        # Weighted vote
        votes = {}
        for sig, conf, w in [(lstm_sig, lstm_conf, self.weights["lstm"]),
                              (xgb_sig,  xgb_conf,  self.weights["xgb"]),
                              (lgbm_sig, lgbm_conf, self.weights["lgbm"])]:
            if sig is None: continue
            if sig not in votes: votes[sig] = 0
            votes[sig] += conf * w

        ensemble_signal = 0
        ensemble_conf   = 0.0
        if votes:
            ensemble_signal = max(votes, key=votes.get)
            total_w = sum(votes.values())
            ensemble_conf = votes.get(ensemble_signal, 0) / max(total_w, 1e-9)

        return {
            "signal":          ensemble_signal,
            "confidence":      ensemble_conf,
            "lstm_signal":     lstm_sig  if lstm_sig  is not None else 0,
            "lstm_conf":       lstm_conf,
            "xgb_signal":      xgb_sig   if xgb_sig   is not None else 0,
            "xgb_conf":        xgb_conf,
            "lgbm_signal":     lgbm_sig  if lgbm_sig  is not None else 0,
            "lgbm_conf":       lgbm_conf,
            "price_target":    df["close"].iloc[-1] * (1 + 0.005 * ensemble_signal),
            "regime":          classify_regime(df),
        }

def classify_regime(df, n=50):
    if len(df) < n: return "unknown"
    atr  = (df["high"] - df["low"]).rolling(14).mean().iloc[-1]
    avg  = (df["high"] - df["low"]).rolling(14).mean().rolling(n).mean().iloc[-1]
    r    = atr / avg if avg > 0 else 1.0
    if r < 0.6: return "ranging"
    if r > 1.4: return "volatile"
    return "trending"

# ════════════════════════════════════════════════════════
#  CSV WRITER (para MQL5)
# ════════════════════════════════════════════════════════
def write_predictions_csv(pred: dict):
    os.makedirs(CSV_DIR, exist_ok=True)
    path = os.path.join(CSV_DIR, "ml_predictions.csv")
    row = [
        datetime.datetime.now().strftime("%Y.%m.%d %H:%M:%S"),
        pred.get("lstm_signal", 0),
        f"{pred.get('lstm_conf', 0):.4f}",
        f"{pred.get('xgb_conf', 0):.4f}",
        f"{pred.get('lgbm_conf', 0):.4f}",
        pred.get("signal", 0),
        f"{pred.get('confidence', 0):.4f}",
        f"{pred.get('price_target', 0):.2f}",
        pred.get("regime", "unknown"),
    ]
    with open(path, "a", newline="") as f:
        writer = csv.writer(f)
        if os.path.getsize(path) == 0:
            writer.writerow(["timestamp","signal","confidence_lstm","confidence_xgb",
                             "confidence_lgbm","ensemble_signal","ensemble_confidence",
                             "price_target","regime"])
        writer.writerow(row)

# ════════════════════════════════════════════════════════
#  TELEGRAM ALERTS
# ════════════════════════════════════════════════════════
def send_telegram(msg: str):
    if not HAS_REQUESTS or not TELEGRAM_TOKEN or not TELEGRAM_CHAT:
        return
    try:
        url  = f"https://api.telegram.org/bot{TELEGRAM_TOKEN}/sendMessage"
        data = {"chat_id": TELEGRAM_CHAT, "text": msg, "parse_mode": "HTML"}
        requests.post(url, data=data, timeout=5)
    except Exception as e:
        log.error(f"Telegram error: {e}")

def alert_signal(pred: dict, account: dict):
    sig_map = {1: "🟢 BUY", -1: "🔴 SELL", 0: "⚪ NEUTRAL"}
    sig_str = sig_map.get(pred.get("signal", 0), "?")
    conf    = pred.get("confidence", 0) * 100
    regime  = pred.get("regime", "?")
    balance = account.get("balance", 0)
    equity  = account.get("equity", 0)
    msg = (
        f"<b>GOLD MASTER — {sig_str}</b>\n"
        f"Confianza: <b>{conf:.1f}%</b>\n"
        f"LSTM: {pred.get('lstm_conf',0)*100:.1f}% | "
        f"XGB: {pred.get('xgb_conf',0)*100:.1f}% | "
        f"LGB: {pred.get('lgbm_conf',0)*100:.1f}%\n"
        f"Régimen: {regime}\n"
        f"Target: {pred.get('price_target',0):.2f}\n"
        f"Balance: ${balance:,.2f} | Equity: ${equity:,.2f}\n"
        f"⏰ {datetime.datetime.now().strftime('%H:%M:%S UTC')}"
    )
    send_telegram(msg)

# ════════════════════════════════════════════════════════
#  MÉTRICAS DE RENDIMIENTO
# ════════════════════════════════════════════════════════
def calc_performance_metrics(deals_df: pd.DataFrame):
    if deals_df.empty:
        return {}
    closed = deals_df[deals_df["entry"] == 1].copy()
    if closed.empty:
        return {}
    returns = closed["profit"].values
    n = len(returns)
    total_pnl  = returns.sum()
    wins       = (returns > 0).sum()
    losses     = (returns < 0).sum()
    win_rate   = wins / n if n > 0 else 0
    avg_win    = returns[returns > 0].mean() if wins > 0 else 0
    avg_loss   = abs(returns[returns < 0].mean()) if losses > 0 else 0
    rr         = avg_win / avg_loss if avg_loss > 0 else 0
    # Equity curve
    equity_curve = np.cumsum(returns)
    peak         = np.maximum.accumulate(equity_curve)
    drawdown     = (equity_curve - peak)
    max_dd       = drawdown.min()
    # Sharpe (anualizado, asumiendo trades diarios)
    if returns.std() > 0:
        sharpe = (returns.mean() / returns.std()) * np.sqrt(252)
    else:
        sharpe = 0
    return {
        "total_pnl":  total_pnl,
        "n_trades":   n,
        "win_rate":   win_rate,
        "avg_win":    avg_win,
        "avg_loss":   avg_loss,
        "rr_ratio":   rr,
        "max_dd":     max_dd,
        "sharpe":     sharpe,
        "equity_curve": equity_curve.tolist(),
    }

# ════════════════════════════════════════════════════════
#  APLICACIÓN DASH
# ════════════════════════════════════════════════════════
mt5mgr   = MT5Manager()
smc_eng  = SMCEngine()
ensemble = EnsembleEngine()

app = dash.Dash(__name__, external_stylesheets=[dbc.themes.DARKLY],
                title="Gold Master v3.1")

# ─── Layout ───────────────────────────────────────────
def make_metric_card(title, value, color="#00d4ff"):
    return dbc.Card(dbc.CardBody([
        html.P(title, className="text-muted mb-0", style={"fontSize":"0.75rem"}),
        html.H5(value, className="mb-0", style={"color": color, "fontWeight":"bold"})
    ]), style={"background":"#1a1a2e","border":"1px solid #333","height":"70px"})

# ─── Intelligence layer v4 (noticias, sentimiento, order flow, bridge) ───
from gm_intel import IntelEngine, register_dash
intel = IntelEngine(SYMBOL)
intel_layout = register_dash(app, intel)
import gm_control
from dash import html as _html
intel_layout = _html.Div([gm_control.register(app, lambda: SYMBOL), intel_layout])
from gm_chart import register_chart
chart_layout = register_chart(app, lambda: SYMBOL, CSV_DIR, intel)

app.layout = dbc.Container([
    intel_layout,
    # Header
    dbc.Row([
        dbc.Col([
            html.H3("⚡ GOLD MASTER SYSTEM v3.1",
                    style={"color":"#ffd700","fontWeight":"bold","marginBottom":"5px"}),
            html.Small(id="last-update", className="text-muted"),
        ], md=8),
        dbc.Col([
            dbc.ButtonGroup([
                dbc.Button("▶ BUY", id="btn-buy",  color="success", size="sm"),
                dbc.Button("▼ SELL",id="btn-sell", color="danger",  size="sm"),
                dbc.Button("✕ CLOSE ALL", id="btn-closeall", color="warning", size="sm"),
            ])
        ], md=4, className="text-end d-flex align-items-center justify-content-end"),
    ], className="mb-2"),

    # Métricas de cuenta
    dbc.Row([
        dbc.Col(make_metric_card("Balance", "$0"), md=2, id="card-balance"),
        dbc.Col(make_metric_card("Equity", "$0",  "#00ff88"), md=2, id="card-equity"),
        dbc.Col(make_metric_card("P&L Día", "$0", "#ffd700"), md=2, id="card-pnl"),
        dbc.Col(make_metric_card("Sharpe", "—",   "#ff88ff"), md=2, id="card-sharpe"),
        dbc.Col(make_metric_card("Win Rate", "—", "#88ffff"), md=2, id="card-winrate"),
        dbc.Col(make_metric_card("Max DD", "—",   "#ff4444"), md=2, id="card-maxdd"),
    ], className="mb-2 g-1"),

    # Fila principal: gráfico + panel ML
    dbc.Row([
        dbc.Col([
            html.Div([chart_layout, dcc.Graph(id="chart-main", style={"display":"none"})])
        ], md=9),
        dbc.Col([
            # Panel ML
            dbc.Card([
                dbc.CardHeader("🤖 ENSEMBLE ML", style={"color":"#ffd700","fontWeight":"bold"}),
                dbc.CardBody([
                    html.Div(id="ml-signal-badge"),
                    html.Hr(),
                    html.Div(id="ml-bars"),
                    html.Hr(),
                    html.Small(id="ml-regime", className="text-muted"),
                    html.Br(),
                    html.Small(id="ml-target",  className="text-muted"),
                ])
            ], style={"background":"#1a1a2e","border":"1px solid #333","marginBottom":"8px"}),
            # SMC Info
            dbc.Card([
                dbc.CardHeader("📊 SMC STATUS", style={"color":"#00d4ff"}),
                dbc.CardBody(html.Div(id="smc-status"))
            ], style={"background":"#1a1a2e","border":"1px solid #333"}),
        ], md=3),
    ], className="mb-2"),

    # Fila: equity curve + session heatmap
    dbc.Row([
        dbc.Col([
            dcc.Graph(id="chart-equity", style={"height":"200px"})
        ], md=6),
        dbc.Col([
            dcc.Graph(id="chart-heatmap", style={"height":"200px"})
        ], md=6),
    ], className="mb-2"),

    # Posiciones + órdenes
    dbc.Row([
        dbc.Col([
            dbc.Card([
                dbc.CardHeader("📌 Posiciones Abiertas"),
                dbc.CardBody(html.Div(id="positions-table"))
            ], style={"background":"#1a1a2e","border":"1px solid #333"}),
        ], md=6),
        dbc.Col([
            dbc.Card([
                dbc.CardHeader("⏳ Órdenes Pendientes"),
                dbc.CardBody(html.Div(id="pending-table"))
            ], style={"background":"#1a1a2e","border":"1px solid #333"}),
        ], md=6),
    ], className="mb-2"),

    # Parámetros de orden manual
    dbc.Row([
        dbc.Col(dbc.Input(id="inp-lot",  type="number", placeholder="Lot",  value=MIN_LOT, step=LOT_STEP, min=MIN_LOT, size="sm"), md=2),
        dbc.Col(dbc.Input(id="inp-sl",   type="number", placeholder="SL $", value=0.0,  step=0.1,  size="sm"), md=2),
        dbc.Col(dbc.Input(id="inp-tp",   type="number", placeholder="TP $", value=0.0,  step=0.1,  size="sm"), md=2),
        dbc.Col(html.Div(id="order-status"), md=6),
    ], className="mb-2"),

    # Interval
    dcc.Interval(id="interval", interval=15_000, n_intervals=0),
    dcc.Store(id="store-pred"),
    dcc.Store(id="store-account"),
], fluid=True, style={"backgroundColor":"#0d0d1a","minHeight":"100vh","padding":"10px"})

# ─── Callbacks ─────────────────────────────────────────
@app.callback(
    Output("chart-main",     "figure"),
    Output("ml-signal-badge","children"),
    Output("ml-bars",        "children"),
    Output("ml-regime",      "children"),
    Output("ml-target",      "children"),
    Output("smc-status",     "children"),
    Output("card-balance",   "children"),
    Output("card-equity",    "children"),
    Output("card-pnl",       "children"),
    Output("card-sharpe",    "children"),
    Output("card-winrate",   "children"),
    Output("card-maxdd",     "children"),
    Output("chart-equity",   "figure"),
    Output("chart-heatmap",  "figure"),
    Output("positions-table","children"),
    Output("pending-table",  "children"),
    Output("last-update",    "children"),
    Output("store-pred",     "data"),
    Output("store-account",  "data"),
    Input("interval",        "n_intervals"),
)
def update_dashboard(n):
    if not mt5mgr.connected:
        mt5mgr.connect()

    df      = mt5mgr.get_bars()
    account = mt5mgr.get_account()
    balance = account.get("balance", 0)
    equity  = account.get("equity",  0)
    pnl     = account.get("profit",  0)
    positions = mt5mgr.get_positions()
    pending   = mt5mgr.get_pending()

    # Retrain si es necesario
    if ensemble.needs_retrain() and len(df) > 500:
        threading.Thread(target=ensemble.train_all, args=(df,), daemon=True).start()

    # Predicción
    pred = {}
    if ensemble.lstm.trained:
        try:
            pred = ensemble.predict(df)          # los modelos se entrenan en hilo aparte: puede que no estén todos listos
            write_predictions_csv(pred)
        except Exception as ex:
            log.info(f"ML aún entrenando: {ex}"); pred = {}
        # Telegram si señal fuerte
        if pred.get("confidence", 0) > 0.70 and pred.get("signal", 0) != 0:
            threading.Thread(target=alert_signal, args=(pred, account), daemon=True).start()

    # Deals para métricas
    deals_df = mt5mgr.get_deals(30)
    metrics  = calc_performance_metrics(deals_df)
    sharpe   = metrics.get("sharpe",   0)
    wr       = metrics.get("win_rate", 0)
    maxdd    = metrics.get("max_dd",   0)
    eq_curve = metrics.get("equity_curve", [])

    # ── Gráfico principal ──────────────────────────────
    fig = make_subplots(rows=2, cols=1, shared_xaxes=True,
                        row_heights=[0.75, 0.25], vertical_spacing=0.03)
    if not df.empty:
        last = df.iloc[-120:]
        fig.add_trace(go.Candlestick(
            x=last.index, open=last["open"], high=last["high"],
            low=last["low"], close=last["close"],
            name=SYMBOL, increasing_line_color="#00ff88",
            decreasing_line_color="#ff4444"), row=1, col=1)
        # EMA
        ema21  = last["close"].ewm(span=21).mean()
        ema50  = last["close"].ewm(span=50).mean()
        ema200 = last["close"].ewm(span=200).mean()
        fig.add_trace(go.Scatter(x=last.index, y=ema21,  name="EMA21",  line=dict(color="#4af",  width=1)), row=1, col=1)
        fig.add_trace(go.Scatter(x=last.index, y=ema50,  name="EMA50",  line=dict(color="#fa4",  width=1)), row=1, col=1)
        fig.add_trace(go.Scatter(x=last.index, y=ema200, name="EMA200", line=dict(color="#f4f",  width=1, dash="dot")), row=1, col=1)
        # FVGs
        fvgs = smc_eng.get_fvgs(df, 30)
        for fvg in fvgs[:5]:
            col = "rgba(0,255,136,0.12)" if fvg["type"]=="bull" else "rgba(255,68,68,0.12)"
            fig.add_hrect(y0=fvg["bot"], y1=fvg["top"], fillcolor=col,
                          line_width=0, row=1, col=1)
        # OBs
        obs = smc_eng.get_obs(df, 20)
        for ob in obs[:4]:
            col = "rgba(0,100,255,0.15)" if ob["type"]=="bull" else "rgba(200,0,150,0.15)"
            fig.add_hrect(y0=ob["bot"], y1=ob["top"], fillcolor=col,
                          line_width=0, row=1, col=1)
        # Equilibrium
        eq = smc_eng.get_equilibrium(df, 50)
        fig.add_hline(y=eq, line_dash="dash", line_color="#555", row=1, col=1)
        # Volumen
        colors_vol = ["#00ff88" if c >= o else "#ff4444"
                      for c, o in zip(last["close"], last["open"])]
        fig.add_trace(go.Bar(x=last.index, y=last["tick_volume"],
                             marker_color=colors_vol, name="Vol", showlegend=False), row=2, col=1)

    fig.update_layout(
        template="plotly_dark", paper_bgcolor="#0d0d1a", plot_bgcolor="#0d0d1a",
        margin=dict(l=50, r=20, t=30, b=20), showlegend=False,
        xaxis_rangeslider_visible=False,
    )

    # ── ML Badge ──────────────────────────────────────
    sig = pred.get("signal", 0)
    conf= pred.get("confidence", 0)
    sig_txt = "🟢 BUY" if sig==1 else ("🔴 SELL" if sig==-1 else "⚪ NEUTRAL")
    sig_col = "#00ff88" if sig==1 else ("#ff4444" if sig==-1 else "#888")
    ml_badge = html.H4(f"{sig_txt}", style={"color": sig_col, "textAlign":"center"})
    ml_bars = html.Div([
        ml_bar("LSTM",  pred.get("lstm_conf",  0)),
        ml_bar("XGBoost", pred.get("xgb_conf", 0)),
        ml_bar("LightGBM",pred.get("lgbm_conf",0)),
        ml_bar("Ensemble",conf, bold=True),
    ])
    ml_regime = f"Régimen: {pred.get('regime', '—')}"
    ml_target = f"Target: ${pred.get('price_target', 0):.2f}"

    # ── SMC Status ────────────────────────────────────
    if not df.empty:
        trend_str = "↑ Bull" if (df["close"].iloc[-1] > df["close"].ewm(50).mean().iloc[-1]) else "↓ Bear"
        eq_val    = smc_eng.get_equilibrium(df, 50)
        eq_zone   = "Discount 🟢" if df["close"].iloc[-1] < eq_val else "Premium 🔴"
        smc_info  = html.Div([
            html.Small(f"Trend: {trend_str}"),    html.Br(),
            html.Small(f"Zona: {eq_zone}"),        html.Br(),
            html.Small(f"EQ: {eq_val:.2f}"),       html.Br(),
            html.Small(f"FVGs: {len(fvgs)} activas"), html.Br(),
            html.Small(f"OBs: {len(obs)} activos"),
        ])
    else:
        smc_info = html.Small("Sin datos")

    # ── Equity curve ──────────────────────────────────
    fig_eq = go.Figure()
    if eq_curve:
        colors_eq = ["#00ff88" if v >= 0 else "#ff4444" for v in eq_curve]
        fig_eq.add_trace(go.Bar(y=eq_curve, marker_color=colors_eq, name="PnL"))
    fig_eq.update_layout(template="plotly_dark", paper_bgcolor="#0d0d1a", plot_bgcolor="#0d0d1a",
                          margin=dict(l=40,r=10,t=20,b=20), title_text="📈 Equity Curve",
                          title_font_color="#ffd700", showlegend=False)

    # ── Session heatmap ───────────────────────────────
    fig_heat = build_session_heatmap(deals_df)

    # ── Métricas cards ────────────────────────────────
    bal_card = make_metric_card("Balance",  f"${balance:,.2f}")
    eq_card  = make_metric_card("Equity",   f"${equity:,.2f}", "#00ff88")
    pnl_col  = "#00ff88" if pnl >= 0 else "#ff4444"
    pnl_card = make_metric_card("P&L Día",  f"${pnl:+,.2f}", pnl_col)
    sha_card = make_metric_card("Sharpe",   f"{sharpe:.2f}", "#ff88ff")
    wr_card  = make_metric_card("Win Rate", f"{wr:.1%}", "#88ffff")
    dd_col   = "#ff4444" if maxdd < -100 else "#aaa"
    dd_card  = make_metric_card("Max DD",   f"${maxdd:,.2f}", dd_col)

    # ── Positions table ───────────────────────────────
    pos_rows = []
    for p in positions:
        col = "#00ff88" if p["profit"] >= 0 else "#ff4444"
        pos_rows.append(html.Tr([
            html.Td(str(p["ticket"]), style={"fontSize":"0.75rem"}),
            html.Td(p["type"]),
            html.Td(str(p["lot"])),
            html.Td(f"{p['open']:.2f}"),
            html.Td(f"{p['sl']:.2f}"),
            html.Td(f"${p['profit']:+.2f}", style={"color":col}),
        ]))
    pos_table = html.Table([
        html.Thead(html.Tr([html.Th("Ticket"), html.Th("Dir"), html.Th("Lot"),
                            html.Th("Entry"), html.Th("SL"), html.Th("P&L")])),
        html.Tbody(pos_rows if pos_rows else [html.Tr(html.Td("Sin posiciones", colSpan=6))])
    ], style={"width":"100%","fontSize":"0.8rem"})

    # ── Pending table ─────────────────────────────────
    pend_rows = []
    for o in pending:
        pend_rows.append(html.Tr([
            html.Td(str(o["ticket"]), style={"fontSize":"0.75rem"}),
            html.Td(o["type"]),
            html.Td(str(o["lot"])),
            html.Td(f"{o['price']:.2f}"),
            html.Td(f"{o['sl']:.2f}"),
        ]))
    pend_table = html.Table([
        html.Thead(html.Tr([html.Th("Ticket"), html.Th("Tipo"), html.Th("Lot"),
                            html.Th("Precio"), html.Th("SL")])),
        html.Tbody(pend_rows if pend_rows else [html.Tr(html.Td("Sin pendientes", colSpan=5))])
    ], style={"width":"100%","fontSize":"0.8rem"})

    upd_str = f"Actualizado: {datetime.datetime.now().strftime('%H:%M:%S')}"

    return (fig, ml_badge, ml_bars, ml_regime, ml_target, smc_info,
            bal_card, eq_card, pnl_card, sha_card, wr_card, dd_card,
            fig_eq, fig_heat,
            pos_table, pend_table, upd_str,
            pred, account)

def ml_bar(name, conf, bold=False):
    col  = "#00ff88" if conf > 0.65 else ("#ffd700" if conf > 0.50 else "#888")
    w    = f"{int(conf*100)}%"
    return html.Div([
        html.Small(f"{name}: {conf:.1%}", style={"fontWeight":"bold" if bold else "normal"}),
        html.Div(html.Div(style={"width":w,"height":"6px","backgroundColor":col,"borderRadius":"3px"}),
                 style={"background":"#333","borderRadius":"3px","marginBottom":"4px"}),
    ])

def build_session_heatmap(deals_df):
    fig = go.Figure()
    if not deals_df.empty and "time" in deals_df.columns:
        try:
            d = deals_df[deals_df["entry"]==1].copy()
            d["hour"] = d["time"].dt.hour
            d["dow"]  = d["time"].dt.dayofweek
            pivot = d.groupby(["dow","hour"])["profit"].mean().unstack(fill_value=0)
            days  = ["Lun","Mar","Mié","Jue","Vie","Sáb","Dom"]
            fig.add_trace(go.Heatmap(
                z=pivot.values, x=list(pivot.columns),
                y=[days[i] for i in pivot.index],
                colorscale="RdYlGn", zmid=0,
                text=pivot.values.round(1),
                texttemplate="%{text}",
            ))
        except Exception:
            pass
    fig.update_layout(template="plotly_dark", paper_bgcolor="#0d0d1a", plot_bgcolor="#0d0d1a",
                      margin=dict(l=40,r=10,t=20,b=20),
                      title_text="🗓 Session Heatmap (PnL promedio)",
                      title_font_color="#ffd700")
    return fig

# ─── Botones de trading ────────────────────────────────
@app.callback(
    Output("order-status", "children"),
    Input("btn-buy", "n_clicks"), Input("btn-sell", "n_clicks"),
    Input("btn-closeall","n_clicks"),
    State("inp-lot", "value"), State("inp-sl", "value"), State("inp-tp", "value"),
    State("store-account", "data"),
    prevent_initial_call=True,
)
def handle_order(buy_n, sell_n, closeall_n, lot, sl, tp, account):
    ctx = callback_context
    if not ctx.triggered: return ""
    btn = ctx.triggered[0]["prop_id"].split(".")[0]
    lot = lot or 0.01
    sl  = sl  or 0.0
    tp  = tp  or 0.0
    if btn == "btn-buy":
        res = mt5mgr.place_order("BUY", SYMBOL, lot, sl, tp, "GM_DASH")
        return html.Span(f"✅ BUY enviado | ticket:{getattr(res,'order',0)}", style={"color":"#00ff88"})
    elif btn == "btn-sell":
        res = mt5mgr.place_order("SELL", SYMBOL, lot, sl, tp, "GM_DASH")
        return html.Span(f"✅ SELL enviado | ticket:{getattr(res,'order',0)}", style={"color":"#ff4444"})
    elif btn == "btn-closeall":
        for p in mt5mgr.get_positions():
            mt5mgr.close_position(p["ticket"])
        return html.Span("✅ Todas las posiciones cerradas", style={"color":"#ffd700"})
    return ""

# ════════════════════════════════════════════════════════
try:
    from gm_pro_chart import register_pro
    from gm_intel import GM_DIR as _GMD
    register_pro(app, lambda: SYMBOL, _GMD)
except Exception as _ex:
    print("Terminal PRO no disponible:", _ex)

if __name__ == "__main__":
    if os.getenv("GM_FOLLOW_SERVICE") == "1":
        intel.follow()            # el servicio gm_service.py calcula; el dashboard sólo lee intel.json
    else:
        intel.start(every_s=20)   # loop noticias/sentimiento/flow + bridge (una sola vez)
    mt5mgr.connect()
    # Primer entrenamiento en background
    df_init = mt5mgr.get_bars()
    if not df_init.empty:
        t = threading.Thread(target=ensemble.train_all, args=(df_init,), daemon=True)
        t.start()
    log.info("Dashboard Gold Master v3.1 en http://127.0.0.1:8050")
    app.run(debug=False, port=8050, host="127.0.0.1")
