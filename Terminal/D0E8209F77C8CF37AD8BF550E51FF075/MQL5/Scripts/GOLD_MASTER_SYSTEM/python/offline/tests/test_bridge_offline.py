"""Verifica el contrato de ficheros del puente EA<->Python (GoldMaster_ML.mqh)."""
import sys
from pathlib import Path

import pandas as pd
import pytest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import gm_bridge as gb  # noqa: E402

pytest.importorskip("sklearn")

HEADER_COLS = ["timestamp", "signal", "confidence_lstm", "confidence_xgb", "confidence_lgbm",
               "ensemble_signal", "ensemble_confidence", "price_target", "regime"]


def _fake_features_csv(path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    pd.DataFrame([{
        "timestamp": "2026.10.12 17:00:00", "symbol": "XAUUSD", "close": 4164.87,
        "atr": 5.29, "ema21": 4167.67, "ema50": 4174.24, "ema200": 4171.96,
        "trend": 0, "dxy_bias": 0, "session": 2, "confluence": 7,
    }]).to_csv(path, index=False)


def _tiny_bundle():
    """Modelo mínimo entrenado con datos sintéticos, para no depender de un CSV real."""
    import numpy as np
    from sklearn.ensemble import HistGradientBoostingClassifier, RandomForestClassifier
    from sklearn.linear_model import LogisticRegression
    from sklearn.preprocessing import StandardScaler
    rng = np.random.default_rng(0)
    X = rng.normal(size=(400, gb.FEATN)); y = (X[:, 2] + rng.normal(scale=0.5, size=400) > 0).astype(int)
    sc = StandardScaler().fit(X)
    return dict(scaler=sc, lr=LogisticRegression(max_iter=500).fit(sc.transform(X), y),
                gb=HistGradientBoostingClassifier(max_iter=50).fit(X, y),
                rf=RandomForestClassifier(n_estimators=40, random_state=0).fit(X, y),
                featn=gb.FEATN, research_only=True)


def test_feat_from_row_length_and_finite():
    import numpy as np
    row = dict(close=4000, atr=5, ema21=4001, ema50=4002, ema200=4003,
               trend=1, dxy_bias=0, session=1, confluence=3)
    f = gb.feat_from_row(row)
    assert len(f) == gb.FEATN
    assert np.isfinite(f).all()


def test_predict_row_ranges():
    p = gb.predict_row(dict(close=4000, atr=5, ema21=4001, ema50=4002, ema200=4003,
                            trend=1, dxy_bias=0, session=1, confluence=3),
                       bundle=_tiny_bundle())
    assert p["signal"] in (-1, 0, 1)
    assert p["ensemble_signal"] in (-1, 0, 1)
    assert 0.0 <= p["ensemble_conf"] <= 1.0
    for k in ("conf_lstm", "conf_xgb", "conf_lgbm"):
        assert 0.0 <= p[k] <= 1.0


def test_predictions_csv_matches_mql5_contract(tmp_path):
    """La predicción escrita debe tener la cabecera y formato que lee CGMLBridge."""
    pred = tmp_path / "ml_predictions.csv"
    p = gb.predict_row(dict(close=4000, atr=5, ema21=4001, ema50=4002, ema200=4003,
                            trend=1, dxy_bias=0, session=1, confluence=3),
                       bundle=_tiny_bundle(), regime="trending")
    gb.write_predictions(pred, pd.Timestamp("2026-10-12 17:00:00"), p, 4000.0)
    df = pd.read_csv(pred)
    assert list(df.columns) == HEADER_COLS
    assert len(df) == 1
    # timestamp en formato MT5 'YYYY.MM.DD HH:MM:SS'
    assert df.iloc[0]["timestamp"] == "2026.10.12 17:00:00"
    assert int(df.iloc[0]["ensemble_signal"]) in (-1, 0, 1)
    assert df.iloc[0]["regime"] == "trending"


def test_serve_once_roundtrip(tmp_path, monkeypatch):
    """EA escribe features -> serve(once) -> predictions.csv válido."""
    monkeypatch.setattr(gb, "_load_bundle", _tiny_bundle)
    _fake_features_csv(tmp_path / "ml_features.csv")
    gb.serve(str(tmp_path), once=True)
    pred = tmp_path / "ml_predictions.csv"
    assert pred.exists()
    df = pd.read_csv(pred)
    assert list(df.columns) == HEADER_COLS and len(df) == 1


def test_read_features_tolerates_missing_file(tmp_path):
    assert gb.read_features(tmp_path / "nope.csv") is None
