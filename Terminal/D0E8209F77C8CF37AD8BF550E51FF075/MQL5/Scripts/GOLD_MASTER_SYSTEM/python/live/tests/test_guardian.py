"""Verifica el gobernador de riesgo y el diario (sin MT5)."""
import sys
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import gm_guardian as G  # noqa: E402

NOW = datetime(2026, 10, 14, 12, 0, tzinfo=timezone.utc)


def gov(sym="XAUUSDmicro"):
    return G.RiskGovernor(G.GuardianConfig(symbol=sym))


def test_allows_normal_and_sizes():
    d = gov().evaluate(12.0, 4.0, dict(regime="normal", spread_points=18, near_news_min=120), now=NOW)
    assert d["allow"] and d["lot"] >= 0.1 and d["risk_usd"] > 0
    assert d["risk_pct"] <= 50


def test_blocks_agitado():
    d = gov().evaluate(50.0, 4.0, dict(regime="agitado"), now=NOW)
    assert not d["allow"] and "agitado" in d["reason"]


def test_blocks_news_blackout():
    d = gov().evaluate(50.0, 4.0, dict(regime="normal", near_news_min=10), now=NOW)
    assert not d["allow"] and "noticia" in d["reason"]


def test_blocks_wide_spread():
    d = gov().evaluate(50.0, 4.0, dict(regime="normal", spread_points=999), now=NOW)
    assert not d["allow"] and "spread" in d["reason"]


def test_daily_loss_and_trade_caps():
    g = gov()
    g.register_result(-1.6, now=NOW)                    # supera stop diario de $1.5 (etapa semilla)
    d = g.evaluate(12.0, 4.0, dict(regime="normal"), now=NOW)
    assert not d["allow"] and "stop diario" in d["reason"]
    g2 = gov()
    for _ in range(3):                                   # etapa semilla: máx 3 ops/día
        g2.register_result(0.1, now=NOW)
    d2 = g2.evaluate(12.0, 4.0, dict(regime="normal"), now=NOW)
    assert not d2["allow"] and "tope diario" in d2["reason"]


def test_min_lot_floor_blocks_tiny_account_on_normal():
    # XAUUSD normal: 0.01 lot * 4$ * 100 = $4 de riesgo; en cuenta de $5 es >50% -> bloquea
    d = gov("XAUUSD").evaluate(5.0, 4.0, dict(regime="normal"), now=NOW)
    assert not d["allow"] and "mínimo" in d["reason"]


def test_journal_record_and_stats(tmp_path):
    j = G.Journal(tmp_path / "j.jsonl")
    j.record(dict(symbol="XAUUSD", side=1, R=1.5, pnl_usd=3.0, ctx=dict(regime="calmo")))
    j.record(dict(symbol="XAUUSD", side=-1, R=-1.0, pnl_usd=-2.0, ctx=dict(regime="agitado")))
    s = j.stats()
    assert s["n"] == 2 and s["with_R"] == 2 and s["net_usd"] == 1.0
    assert "calmo" in s["by_regime"] and s["by_regime"]["calmo"]["exp"] == 1.5


def test_learn_needs_min_trades(tmp_path):
    j = G.Journal(tmp_path / "j.jsonl")
    j.record(dict(R=1.0, ctx=dict(regime="normal")))
    out = G.learn_from_journal(j, min_trades=60)
    assert out["trained"] is False and "faltan" in out["reason"]
