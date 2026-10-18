"""Pruebas de la ecuación maestra del oro y del cargador de datos.

Incluye una regresión explícita del bug de alineación de pandas que dejaba
todas las columnas en NaN (gm_data.load): es silencioso y catastrófico, así
que tiene que quedar clavado con una prueba.
"""
import math
import sys
from pathlib import Path

import numpy as np
import pandas as pd
import pytest

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE.parent), str(HERE.parent.parent / "core")]

import gm_data  # noqa: E402
from gm_gold_sde import (GoldSDE, _gpd_icdf, calibrate, prepare,  # noqa: E402
                         simulate, SCALE)


# ───────────────────────── gm_data ─────────────────────────


def _write_mt5_tsv(path: Path, n: int = 50) -> None:
    """Escribe un fichero en el formato exacto que exporta MetaTrader 5."""
    lines = ["<DATE>\t<TIME>\t<OPEN>\t<HIGH>\t<LOW>\t<CLOSE>\t<TICKVOL>\t<VOL>\t<SPREAD>"]
    for i in range(n):
        px = 2000.0 + i
        lines.append(f"2024.01.{1 + i // 24:02d}\t{i % 24:02d}:00:00\t"
                     f"{px:.2f}\t{px + 2:.2f}\t{px - 2:.2f}\t{px + 1:.2f}\t100\t0\t30")
    path.write_text("\n".join(lines), encoding="utf-8")


def test_load_mt5_tsv_no_nan_regression(tmp_path):
    """REGRESIÓN: df[col] trae RangeIndex y pandas lo alineaba contra el
    DatetimeIndex, dejando TODA la columna en NaN sin avisar."""
    f = tmp_path / "XAUUSD_H1.csv"
    _write_mt5_tsv(f, 48)
    df = gm_data.load(f)
    assert len(df) == 48
    assert not df[["open", "high", "low", "close"]].isna().any().any()
    assert df["close"].iloc[0] == pytest.approx(2001.0)
    assert df["high"].iloc[0] == pytest.approx(2002.0)
    assert isinstance(df.index, pd.DatetimeIndex)
    assert df.index.is_monotonic_increasing


def test_load_rejects_file_without_close(tmp_path):
    f = tmp_path / "malo.csv"
    f.write_text("fecha,algo\n2024-01-01,5\n", encoding="utf-8")
    with pytest.raises(ValueError, match="cierre"):
        gm_data.load(f)


def test_load_drops_nonpositive_prices(tmp_path):
    f = tmp_path / "ceros.csv"
    f.write_text("Date,close\n2024-01-01,100\n2024-01-02,0\n2024-01-03,-5\n"
                 "2024-01-04,110\n", encoding="utf-8")
    df = gm_data.load(f)
    assert len(df) == 2 and (df["close"] > 0).all()


def test_resample_aggregates_ohlc(tmp_path):
    f = tmp_path / "h1.csv"
    _write_mt5_tsv(f, 24)
    d1 = gm_data.resample(gm_data.load(f), "1D")
    assert len(d1) == 1
    assert d1["high"].iloc[0] == pytest.approx(2025.0)   # máximo del día
    assert d1["low"].iloc[0] == pytest.approx(1998.0)    # mínimo del día


# ───────────────────────── utilidades del modelo ─────────────────────────


def test_gpd_icdf_reduces_to_exponential():
    """Con ξ=0 la Pareto generalizada ES la exponencial: media = β."""
    u = np.random.default_rng(0).random(200_000)
    x = _gpd_icdf(u, 0.0, 2.0)
    assert x.min() >= 0
    assert np.mean(x) == pytest.approx(2.0, rel=0.02)


def test_gpd_icdf_heavier_tail_with_positive_shape():
    u = np.linspace(0.001, 0.999, 1000)
    assert _gpd_icdf(u, 0.3, 1.0)[-1] > _gpd_icdf(u, 0.0, 1.0)[-1]


def test_prepare_requires_datetime_index():
    df = pd.DataFrame({"close": [1.0, 2.0, 3.0]})
    with pytest.raises(ValueError, match="DatetimeIndex"):
        prepare(df)


def test_prepare_computes_log_returns_in_percent():
    idx = pd.date_range("2024-01-01", periods=3, freq="1h")
    df = pd.DataFrame({"close": [100.0, 110.0, 99.0]}, index=idx)
    out = prepare(df)
    assert out["r_pct"].iloc[0] == pytest.approx(100 * math.log(1.1), rel=1e-9)


# ───────────────────────── calibración ─────────────────────────


@pytest.fixture(scope="module")
def fitted():
    """Calibra sobre una serie sintética con volatilidad agrupada conocida."""
    rng = np.random.default_rng(42)
    n = 6000
    sig = np.empty(n)
    sig[0] = 0.25
    r = np.empty(n)
    for i in range(n):          # GARCH(1,1) generador conocido
        r[i] = sig[i] * rng.standard_t(5) * math.sqrt(3 / 5)
        if i + 1 < n:
            sig[i + 1] = math.sqrt(1.5e-3 + 0.06 * r[i] ** 2 + 0.92 * sig[i] ** 2)
    px = 1800.0 * np.exp(np.cumsum(r / SCALE))
    idx = pd.date_range("2015-01-01", periods=n, freq="1h")
    return calibrate(pd.DataFrame({"close": px}, index=idx))


def test_calibrate_recovers_garch_persistence(fitted):
    m, _ = fitted
    assert 0.80 < m.garch_alpha + m.garch_beta < 1.0
    assert m.garch_nu > 2.0
    assert m.uncond_vol_pct > 0


def test_calibrate_rejects_short_series():
    idx = pd.date_range("2024-01-01", periods=100, freq="1h")
    df = pd.DataFrame({"close": np.linspace(100, 110, 100)}, index=idx)
    with pytest.raises(ValueError, match="2000"):
        calibrate(df)


def test_seasonal_is_rms_normalised(fitted):
    m, _ = fitted
    assert len(m.seasonal) == 24
    assert float(np.sqrt(np.mean(np.asarray(m.seasonal) ** 2))) == pytest.approx(1.0, abs=0.02)


def test_regimes_sorted_by_volatility(fitted):
    """calmo < normal < agitado, siempre: los parámetros guardados dependen
    de que el índice 0 sea el régimen tranquilo."""
    m, _ = fitted
    assert m.regime_vol_mult[0] <= m.regime_vol_mult[1] <= m.regime_vol_mult[2]
    assert sum(m.regime_steady) == pytest.approx(1.0, abs=1e-6)
    for row in m.regime_transmat:
        assert sum(row) == pytest.approx(1.0, abs=1e-6)


def test_regimes_switch_on_daily_cadence(fitted):
    """El régimen debe conmutar a ritmo diario, no horario (si no, el
    drawdown simulado sale subestimado)."""
    m, _ = fitted
    assert m.regime_bars > 1
    assert all(d >= 1.0 for d in m.regime_duration_days)


def test_diagnostics_shape_and_columns(fitted):
    m, diag = fitted
    assert {"r_pct", "sigma_pct", "z", "epsilon", "jump", "regime"} <= set(diag.columns)
    assert diag["regime"].isin([0, 1, 2]).all()
    assert (diag["sigma_pct"] > 0).all()


# ───────────────────────── simulación ─────────────────────────


def test_simulate_shape_and_positive(fitted):
    m, _ = fitted
    p = simulate(m, n_paths=40, n_steps=200, s0=1800.0, seed=1)
    assert p.shape == (40, 201)
    assert (p > 0).all() and np.isfinite(p).all()
    assert p[:, 0] == pytest.approx(1800.0)


def test_simulate_is_reproducible(fitted):
    m, _ = fitted
    a = simulate(m, n_paths=20, n_steps=100, seed=7)
    b = simulate(m, n_paths=20, n_steps=100, seed=7)
    assert np.array_equal(a, b)
    assert not np.array_equal(a, simulate(m, n_paths=20, n_steps=100, seed=8))


def test_stats_only_matches_full_paths(fitted):
    """El modo streaming debe dar exactamente el mismo drawdown que calcular
    sobre los caminos completos — si no, las dos rutas divergen en silencio."""
    m, _ = fitted
    kw = dict(n_paths=30, n_steps=300, s0=1.0, seed=3)
    paths = simulate(m, **kw)
    st = simulate(m, stats_only=True, **kw)
    peak = np.maximum.accumulate(paths, axis=1)
    dd_full = (paths / peak - 1.0).min(axis=1)
    assert np.allclose(dd_full, st["max_dd"], atol=1e-5)
    assert np.allclose(paths[:, -1], st["final"], rtol=1e-5)


def test_zero_drift_gives_deeper_drawdowns(fitted):
    """Quitar el viento de cola secular debe ENSANCHAR la banda de drawdown.
    Es la base de usar β=0 para dimensionar riesgo."""
    m, _ = fitted
    m.beta = 0.08                                  # deriva positiva fuerte
    hist = simulate(m, n_paths=300, n_steps=4000, seed=5, stats_only=True)
    neutral = simulate(m, n_paths=300, n_steps=4000, seed=5, drift_annual=0.0,
                       stats_only=True)
    assert np.median(neutral["max_dd"]) < np.median(hist["max_dd"])


def test_jumps_increase_kurtosis(fitted):
    """include_jumps=True debe engordar las colas — por eso está en False por
    defecto: sumado al GARCH-t cuenta las colas dos veces."""
    from scipy import stats as st

    m, _ = fitted
    m.jump_gpd_scale = 0.5
    m.jump_lambda_year = 200.0
    m.regime_lambda_year = [200.0, 200.0, 200.0]
    base = simulate(m, n_paths=60, n_steps=2000, seed=2, include_jumps=False)
    wj = simulate(m, n_paths=60, n_steps=2000, seed=2, include_jumps=True)
    k = lambda a: float(np.mean([st.kurtosis(row, fisher=False) for row in
                                 np.diff(np.log(a), axis=1)]))
    assert k(wj) > k(base)


def test_params_roundtrip_json(tmp_path, fitted):
    m, _ = fitted
    f = tmp_path / "p.json"
    m.to_json(f)
    back = GoldSDE.from_json(f)
    assert back.garch_alpha == m.garch_alpha
    assert back.seasonal == m.seasonal
    assert back.regime_transmat == m.regime_transmat
    assert "ECUACIÓN MAESTRA" in back.equation_text()
