"""
gm_orderblocks_pro.py — Detector EXHAUSTIVO de order blocks (todos los escenarios).

Un order block es la última vela contraria antes de un desplazamiento que rompe
estructura. A partir de esa definición, la literatura SMC describe una familia de
escenarios que este módulo detecta y ETIQUETA por separado, para que después se
pueda medir CUÁL de ellos tiene esperanza positiva y cuál no:

  ESCENARIOS (campo `subtype`)
    classic      OB canónico: última vela contraria antes del desplazamiento
    breaker      OB que falló (el precio lo atravesó) y ahora actúa del lado opuesto
    mitigation   el precio volvió y mitigó parcialmente la zona
    rejection    vela de mecha dominante: la zona operable es la mecha, no el cuerpo
    propulsion   OB anidado dentro de otro OB previo del mismo sentido

  ATRIBUTOS ORTOGONALES (uno o varios a la vez)
    sweep_before      hubo barrido de liquidez (stop-run) justo antes de formarse
    fvg_paired        lleva pegado un hueco de valor justo (imbalance de 3 velas)
    is_extreme        está en el extremo del rango, no en el medio (decisional)
    vol_spike         volumen de ticks anómalo en la formación
    bos_confirmed     el desplazamiento rompió de verdad el swing estructural
    nested_htf        coincide con un OB de temporalidad superior
    session           asia | london | ny  (hora UTC de formación)
    state             unmitigated | touched | consumed

  REFINAMIENTOS DE ZONA (campo `zone_*`)
    full   mecha a mecha      body  cuerpo de la vela      eq  50% (equilibrio/OTE)

────────────────────────────────────────────────────────────────────────────────
REGLA DURA ANTI-LOOK-AHEAD
────────────────────────────────────────────────────────────────────────────────
Cada OB lleva DOS índices distintos y no son intercambiables:

    ob_index       la vela que forma el bloque
    confirm_index  la vela cuyo CIERRE confirma el desplazamiento y el BOS

Un operador real no puede saber que existe el OB hasta que cierra la vela
`confirm_index`. Por eso toda entrada tiene que ocurrir en barras
ESTRICTAMENTE POSTERIORES a confirm_index, y las funciones de backtest de este
paquete lo imponen. Usar ob_index como momento de entrada es el error que
infla cualquier backtest de SMC, porque equivale a comprar en el mínimo
sabiendo ya que venía el impulso.
"""
from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np
import pandas as pd


@dataclass
class OBConfig:
    """Umbrales del detector. Los valores por omisión salen del barrido sobre
    datos reales de 21 años; cámbialos por símbolo, no por corazonada."""

    atr_period: int = 14
    #: desplazamiento mínimo del cuerpo, en múltiplos de ATR
    disp_atr: float = 2.5
    #: ventana hacia atrás para buscar la vela contraria que forma el OB
    ob_lookback: int = 5
    #: k de los fractales que definen swing alto/bajo
    swing_k: int = 3
    #: ventana para detectar barrido de liquidez antes del OB
    sweep_window: int = 10
    #: mecha/cuerpo a partir del cual la vela es de rechazo
    rejection_ratio: float = 2.0
    #: volumen de ticks que se considera pico, en múltiplos de la mediana
    vol_spike_mult: float = 1.8
    #: ventana para decidir si el OB está en el extremo del rango
    extreme_window: int = 50
    #: fracción del rango que delimita la franja "extrema"
    extreme_frac: float = 0.25
    #: barras máximas que un OB sigue vivo (0 = sin caducidad)
    max_age: int = 240
    #: antigüedad máxima, EN BARRAS, de un OB opuesto para que su invalidación
    #: cuente como breaker. Sin este límite cualquier impulso grande cruza
    #: alguna zona vieja y el 83% de los bloques se etiquetaba como breaker.
    breaker_window: int = 200


# ───────────────────────── indicadores base ─────────────────────────


def atr(df: pd.DataFrame, n: int) -> np.ndarray:
    """ATR de Wilder, desplazado: en la barra i solo usa información ≤ i−1.

    El desplazamiento es deliberado. Si el ATR de la barra i incluyera el rango
    de la propia barra i, el umbral de desplazamiento se compararía contra una
    medida que ya contiene el movimiento que queremos detectar, y las velas
    grandes se auto-descartarían.
    """
    h, l, c = (df[k].to_numpy(dtype=float) for k in ("high", "low", "close"))
    pc = np.concatenate([[c[0]], c[:-1]])
    tr = np.maximum(h - l, np.maximum(np.abs(h - pc), np.abs(l - pc)))
    out = pd.Series(tr).ewm(alpha=1.0 / n, adjust=False).mean().to_numpy()
    return np.concatenate([[np.nan], out[:-1]])


def swings(df: pd.DataFrame, k: int) -> tuple[np.ndarray, np.ndarray]:
    """Marca swings fractales confirmados. Un swing en i se CONFIRMA en i+k.

    Devuelve (swing_high, swing_low) como arrays booleanos indexados por la
    barra del pivote. Quien los consuma debe recordar que el pivote i no es
    conocible hasta i+k.
    """
    h, l = df["high"].to_numpy(dtype=float), df["low"].to_numpy(dtype=float)
    n = len(df)
    sh, sl = np.zeros(n, bool), np.zeros(n, bool)
    for i in range(k, n - k):
        w_h, w_l = h[i - k:i + k + 1], l[i - k:i + k + 1]
        if h[i] == w_h.max() and (w_h.argmax() == k):
            sh[i] = True
        if l[i] == w_l.min() and (w_l.argmin() == k):
            sl[i] = True
    return sh, sl


def _last_swing_before(idx: int, mask: np.ndarray, vals: np.ndarray,
                       k: int) -> tuple[int, float]:
    """Último swing CONFIRMADO antes de la barra idx (pivote ≤ idx−k−1)."""
    hi = idx - k - 1
    if hi < 0:
        return -1, np.nan
    cand = np.flatnonzero(mask[:hi + 1])
    if len(cand) == 0:
        return -1, np.nan
    j = int(cand[-1])
    return j, float(vals[j])


def _session(hour: int) -> str:
    if 0 <= hour < 7:
        return "asia"
    if 7 <= hour < 13:
        return "london"
    return "ny"


# ───────────────────────── detección ─────────────────────────


def detect(df: pd.DataFrame, cfg: OBConfig | None = None) -> pd.DataFrame:
    """Detecta todos los order blocks de la serie y los devuelve etiquetados.

    `df` necesita índice datetime y columnas open/high/low/close (volume opcional).
    Devuelve un DataFrame, una fila por OB, con geometría, escenario y contexto.
    """
    cfg = cfg or OBConfig()
    if len(df) < max(cfg.atr_period, cfg.extreme_window) + 2 * cfg.swing_k + 5:
        return pd.DataFrame()

    o = df["open"].to_numpy(dtype=float)
    h = df["high"].to_numpy(dtype=float)
    l = df["low"].to_numpy(dtype=float)
    c = df["close"].to_numpy(dtype=float)
    v = (df["volume"].to_numpy(dtype=float) if "volume" in df.columns
         else np.zeros(len(df)))
    n = len(df)
    a = atr(df, cfg.atr_period)
    sh, sl = swings(df, cfg.swing_k)
    vol_med = np.nanmedian(v[v > 0]) if (v > 0).any() else 0.0
    hours = df.index.hour.to_numpy()

    body = c - o
    rows: list[dict] = []

    for i in range(cfg.ob_lookback + cfg.swing_k + 1, n):
        if not np.isfinite(a[i]) or a[i] <= 0:
            continue
        # ¿la vela i es un desplazamiento?
        if abs(body[i]) < cfg.disp_atr * a[i]:
            continue
        bullish = body[i] > 0

        # --- la vela contraria más reciente antes del desplazamiento: el OB ---
        ob = -1
        for j in range(i - 1, max(-1, i - 1 - cfg.ob_lookback), -1):
            if (body[j] < 0) if bullish else (body[j] > 0):
                ob = j
                break
        if ob < 0:
            continue

        # --- BOS: ¿el desplazamiento rompió el swing estructural? ---
        if bullish:
            sw_i, sw_v = _last_swing_before(i, sh, h, cfg.swing_k)
            bos = bool(np.isfinite(sw_v) and c[i] > sw_v)
        else:
            sw_i, sw_v = _last_swing_before(i, sl, l, cfg.swing_k)
            bos = bool(np.isfinite(sw_v) and c[i] < sw_v)

        # --- barrido de liquidez justo antes del OB ---
        sweep = False
        lo_w = max(0, ob - cfg.sweep_window)
        if bullish:
            pj, pv = _last_swing_before(ob, sl, l, cfg.swing_k)
            if np.isfinite(pv) and pj >= lo_w - cfg.swing_k:
                # mecha por debajo del swing previo pero cierre por encima
                seg = slice(max(pj + 1, lo_w), ob + 1)
                sweep = bool((l[seg] < pv).any() and c[ob] > pv)
        else:
            pj, pv = _last_swing_before(ob, sh, h, cfg.swing_k)
            if np.isfinite(pv) and pj >= lo_w - cfg.swing_k:
                seg = slice(max(pj + 1, lo_w), ob + 1)
                sweep = bool((h[seg] > pv).any() and c[ob] < pv)

        # --- hueco de valor justo (FVG) creado por la vela de DESPLAZAMIENTO ---
        # El imbalance canonico son las velas (i-1, i, i+1) alrededor del
        # desplazamiento, NO las de alrededor del OB: es el hueco que deja el
        # impulso al saltarse el precio. Como la definicion usa i+1, el FVG no
        # se conoce hasta que cierra esa barra, asi que se publica su propio
        # indice (`fvg_known_index`) y el backtest exige entrar despues de el.
        fvg = False
        fvg_top = fvg_bot = np.nan
        fvg_known = -1
        if 0 < i < n - 1:
            if bullish and l[i + 1] > h[i - 1]:
                fvg, fvg_bot, fvg_top, fvg_known = True, h[i - 1], l[i + 1], i + 1
            elif (not bullish) and h[i + 1] < l[i - 1]:
                fvg, fvg_bot, fvg_top, fvg_known = True, h[i + 1], l[i - 1], i + 1

        # --- vela de rechazo: mecha dominante ---
        rng = max(h[ob] - l[ob], 1e-12)
        bod = max(abs(body[ob]), 1e-12)
        upper_w, lower_w = h[ob] - max(o[ob], c[ob]), min(o[ob], c[ob]) - l[ob]
        wick = lower_w if bullish else upper_w
        rejection = bool(wick / bod >= cfg.rejection_ratio)

        # --- posición en el rango: extremo o decisional ---
        w0 = max(0, ob - cfg.extreme_window)
        hi_r, lo_r = h[w0:ob + 1].max(), l[w0:ob + 1].min()
        span = max(hi_r - lo_r, 1e-12)
        pos = (c[ob] - lo_r) / span
        is_extreme = bool(pos <= cfg.extreme_frac or pos >= 1 - cfg.extreme_frac)

        rows.append({
            "kind": "bullish" if bullish else "bearish",
            "ob_index": int(ob),
            "confirm_index": int(i),          # NO operable antes de esta barra
            "ob_time": df.index[ob],
            "confirm_time": df.index[i],
            # geometría: tres refinamientos de zona
            "zone_full_top": float(h[ob]), "zone_full_bot": float(l[ob]),
            "zone_body_top": float(max(o[ob], c[ob])),
            "zone_body_bot": float(min(o[ob], c[ob])),
            "zone_eq": float((h[ob] + l[ob]) / 2.0),
            "ob_range": float(rng),
            "ob_range_atr": float(rng / a[i]),
            # fuerza del desplazamiento
            "disp_atr": float(abs(body[i]) / a[i]),
            "disp_range_atr": float((h[i] - l[i]) / a[i]),
            "atr_at_confirm": float(a[i]),
            "disp_open": float(o[i]), "disp_close": float(c[i]),
            # atributos ortogonales
            "bos_confirmed": bos,
            "sweep_before": sweep,
            "fvg_paired": fvg,
            "fvg_top": float(fvg_top) if fvg else np.nan,
            "fvg_bot": float(fvg_bot) if fvg else np.nan,
            "fvg_known_index": int(fvg_known),
            "rejection": rejection,
            "wick_body_ratio": float(wick / bod),
            "is_extreme": is_extreme,
            "range_pos": float(pos),
            "vol_spike": bool(vol_med > 0 and v[ob] > cfg.vol_spike_mult * vol_med),
            "vol_ratio": float(v[ob] / vol_med) if vol_med > 0 else 0.0,
            "session": _session(int(hours[ob])),
            "hour": int(hours[ob]),
        })

    if not rows:
        return pd.DataFrame()
    obs = pd.DataFrame(rows)
    obs = _classify_subtypes(obs, cfg)
    obs = _track_state(obs, h, l, c, cfg)
    return obs.reset_index(drop=True)


def _classify_subtypes(obs: pd.DataFrame, cfg: OBConfig) -> pd.DataFrame:
    """Asigna el escenario: propulsion (anidado), breaker (invalidó al opuesto),
    rejection (mecha dominante), mitigation (sin BOS) o classic."""
    obs = obs.sort_values("confirm_index").reset_index(drop=True)
    sub = np.array(["classic"] * len(obs), dtype=object)
    prop = np.zeros(len(obs), bool)
    brk = np.zeros(len(obs), bool)

    for idx in range(len(obs)):
        r = obs.iloc[idx]
        top, bot = r["zone_full_top"], r["zone_full_bot"]
        # mira solo OBs YA confirmados antes que este: nada de futuro
        prev = obs.iloc[:idx]
        prev = prev[prev["confirm_index"] < r["confirm_index"]]
        if len(prev) == 0:
            continue
        recent = prev[prev["confirm_index"] >= r["confirm_index"] - cfg.breaker_window]
        same = recent[recent["kind"] == r["kind"]]
        opp = recent[recent["kind"] != r["kind"]]
        # anidado: solapa una zona previa del mismo sentido
        if len(same) and ((same["zone_full_top"] >= bot) &
                          (same["zone_full_bot"] <= top)).any():
            prop[idx] = True
        # breaker: el CUERPO del desplazamiento atraviesa la zona de un OB
        # opuesto, invalidandola. Se exige solapamiento real con el recorrido
        # [open, close] de la vela de impulso, no la mera existencia de una
        # zona opuesta en las cercanias.
        if len(opp):
            lo_body = min(r["disp_open"], r["disp_close"])
            hi_body = max(r["disp_open"], r["disp_close"])
            crossed = ((opp["zone_full_bot"] <= hi_body) &
                       (opp["zone_full_top"] >= lo_body))
            brk[idx] = bool(crossed.any())

    for idx in range(len(obs)):
        if brk[idx]:
            sub[idx] = "breaker"
        elif prop[idx]:
            sub[idx] = "propulsion"
        elif obs.at[idx, "rejection"]:
            sub[idx] = "rejection"
        elif not obs.at[idx, "bos_confirmed"]:
            sub[idx] = "mitigation"
    obs["subtype"] = sub
    obs["propulsion"] = prop
    obs["breaker"] = brk
    return obs


def _track_state(obs: pd.DataFrame, h: np.ndarray, l: np.ndarray,
                 c: np.ndarray, cfg: OBConfig) -> pd.DataFrame:
    """Marca, a futuro del confirm_index, si la zona fue tocada o consumida.

    Es información POSTERIOR: vale para estadística descriptiva y etiquetado,
    nunca como filtro de entrada. Por eso el campo se llama state y no señal.
    """
    n = len(h)
    first_touch, state = [], []
    for _, r in obs.iterrows():
        s = int(r["confirm_index"]) + 1
        e = n if cfg.max_age <= 0 else min(n, s + cfg.max_age)
        top, bot = r["zone_full_top"], r["zone_full_bot"]
        ft, stt = -1, "unmitigated"
        if s < e:
            inside = np.flatnonzero((l[s:e] <= top) & (h[s:e] >= bot))
            if len(inside):
                ft = s + int(inside[0])
                stt = "touched"
                # consumido: cierre al otro lado de la zona
                after = slice(ft, e)
                if r["kind"] == "bullish" and (c[after] < bot).any():
                    stt = "consumed"
                elif r["kind"] == "bearish" and (c[after] > top).any():
                    stt = "consumed"
        first_touch.append(ft)
        state.append(stt)
    obs["first_touch_index"] = first_touch
    obs["state"] = state
    obs["bars_to_touch"] = [
        (ft - ci) if ft >= 0 else -1
        for ft, ci in zip(first_touch, obs["confirm_index"])
    ]
    return obs


def nest_htf(obs_ltf: pd.DataFrame, obs_htf: pd.DataFrame) -> pd.DataFrame:
    """Marca los OB de temporalidad baja que caen dentro de un OB superior.

    El OB superior solo cuenta si su confirm_time es ANTERIOR o igual al
    confirm_time del inferior: un POI de H4 que se confirma más tarde no podía
    estar en la pantalla cuando apareció el de H1.
    """
    if obs_ltf.empty or obs_htf.empty:
        out = obs_ltf.copy()
        out["nested_htf"] = False
        return out
    out = obs_ltf.copy()
    flags = []
    for _, r in out.iterrows():
        cand = obs_htf[(obs_htf["confirm_time"] <= r["confirm_time"]) &
                       (obs_htf["kind"] == r["kind"])]
        if cand.empty:
            flags.append(False)
            continue
        cand = cand.tail(20)
        flags.append(bool(((cand["zone_full_top"] >= r["zone_full_bot"]) &
                           (cand["zone_full_bot"] <= r["zone_full_top"])).any()))
    out["nested_htf"] = flags
    return out


def summary(obs: pd.DataFrame) -> pd.DataFrame:
    """Recuento por escenario y sentido, con tasa de toque y de consumo."""
    if obs.empty:
        return pd.DataFrame()
    g = obs.groupby(["subtype", "kind"])
    return pd.DataFrame({
        "n": g.size(),
        "pct_tocados": 100.0 * g.apply(
            lambda d: (d["state"] != "unmitigated").mean(), include_groups=False),
        "pct_consumidos": 100.0 * g.apply(
            lambda d: (d["state"] == "consumed").mean(), include_groups=False),
        "barras_a_toque_mediana": g.apply(
            lambda d: d.loc[d["bars_to_touch"] >= 0, "bars_to_touch"].median(),
            include_groups=False),
        "disp_atr_medio": g["disp_atr"].mean(),
        "pct_con_sweep": 100.0 * g["sweep_before"].mean(),
        "pct_con_fvg": 100.0 * g["fvg_paired"].mean(),
        "pct_extremos": 100.0 * g["is_extreme"].mean(),
    }).round(2)


FEATURES = [
    "disp_atr", "disp_range_atr", "ob_range_atr", "wick_body_ratio",
    "range_pos", "vol_ratio", "hour",
    "bos_confirmed", "sweep_before", "fvg_paired", "rejection", "is_extreme",
    "vol_spike", "propulsion", "breaker",
]

#: Preset con umbral de desplazamiento menor. Detecta muchos mas bloques, lo
#: que hace falta para entrenar: con 1.395 OB y 15 features el modelo no tiene
#: datos suficientes. Es un preset de INVESTIGACION, no de operativa: bajar el
#: umbral tambien mete bloques de impulso debil.
RELAXED = OBConfig(disp_atr=1.5, ob_lookback=6, rejection_ratio=1.6)

__all__ = ["OBConfig", "RELAXED", "detect", "summary", "nest_htf", "atr",
           "swings", "FEATURES"]
