"""DataManager: validación, huecos, remuestreo, caché SQLite."""
import pandas as pd
import pytest

from data.data_manager import DataManager, detect_gaps, resample_ohlc, validate_bars
from storage.database import Database


def test_validate_cleans(history_m1):
    df = history_m1.head(100).copy()
    df = pd.concat([df, df.iloc[[5]]])                  # duplicado
    df.loc[df.index[10], "high"] = df["low"].iloc[10] - 1   # OHLC imposible
    df = df.sample(frac=1, random_state=1)              # desordenado
    out, rep = validate_bars(df, "M1")
    assert rep.duplicates == 1 and rep.invalid_ohlc >= 1 and rep.unsorted
    assert out["time"].is_monotonic_increasing and out["time"].is_unique


def test_gaps_detected_not_filled(history_m1):
    df = history_m1.head(300).drop(index=range(100, 130))
    gaps = detect_gaps(df, "M1")
    assert len(gaps) == 1 and gaps[0]["missing_bars"] == 30
    assert len(df) == 270        # no se fabrican velas


def test_resample_matches_manual(history_m1):
    df = history_m1.head(120)
    m15 = resample_ohlc(df, "M1", "M15")
    first = df.head(15)
    r = m15.iloc[0]
    assert r.open == first.open.iloc[0] and r.close == first.close.iloc[-1]
    assert r.high == first.high.max() and r.low == first.low.min()
    assert len(m15) == 8 and m15["complete"].all()
    with pytest.raises(ValueError):
        resample_ohlc(df, "M5", "M1")


def test_cache_roundtrip(history_m1, tmp_path):
    db = Database(tmp_path / "c.db")
    db.upsert_candles("XAUUSD", "M1", history_m1.head(500))
    db.upsert_candles("XAUUSD", "M1", history_m1.head(500))          # idempotente
    back = db.load_candles("XAUUSD", "M1")
    assert len(back) == 500 and back["close"].iloc[-1] == history_m1["close"].iloc[499]
    dm = DataManager(db)
    df, rep = dm.get_bars("XAUUSD", "M1", 300, use_mt5=False)        # offline => caché
    assert len(df) == 300


def test_offline_without_cache_fails_clearly(tmp_path):
    with pytest.raises(RuntimeError):
        DataManager(Database(tmp_path / "e.db")).get_bars("XAUUSD", "M1", 10, use_mt5=False)


def test_drawings_persist(tmp_path):
    db = Database(tmp_path / "d.db")
    i = db.save_drawing("XAUUSD", "H1", "fib", {"t1": "2026-01-01T00:00:00+00:00", "p1": 1, "t2": "x", "p2": 2},
                        {"color": "#fff"}, "2026-01-01")
    d = db.load_drawings("XAUUSD", "H1")
    assert d[0]["id"] == i and d[0]["coordinates"]["p2"] == 2
    db.delete_drawing(i)
    assert db.load_drawings("XAUUSD") == []
