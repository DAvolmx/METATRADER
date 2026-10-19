"""
gm_sentiment.py — Sentimiento del oro, construido con lo que se puede medir.

Advertencia de honestidad, por delante de todo lo demás: esto NO lee la mente
del mercado. "Sentimiento" aquí significa **internos de mercado derivados del
precio**, más las fuentes externas que tengas conectadas. Un índice de
sentimiento construido con el precio es, por definición, una función del
precio: puede describir el estado del mercado, y no debe presentarse como una
fuente de información independiente de él.

Lo que sí aporta: un resumen comparable y reproducible del estado del oro, con
cada componente normalizado por su propia historia, de modo que "miedo alto" o
"complacencia" signifiquen siempre lo mismo. Y una medición explícita de si ese
resumen anticipa algo — que es la pregunta que casi nadie hace a su indicador
de sentimiento.

COMPONENTES DERIVADOS DEL PRECIO (los 9 se calculan solo con OHLCV)
  tendencia      posición dentro del rango de N días y distancia a la media
  momento        retorno acumulado reciente, normalizado por volatilidad
  miedo          percentil de la volatilidad realizada en su propia historia
  sesgo          asimetría realizada de los retornos recientes
  drawdown       distancia al máximo reciente
  expansion      ATR corto frente a ATR largo (compresión vs expansión)
  estres         frecuencia de saltos (|r| > 4σ) en la ventana reciente
  sesiones       qué sesión domina el movimiento (Asia defensiva vs NY riesgo)
  intensidad     volumen de ticks frente a su normal

FUENTES EXTERNAS (opcionales, con degradación limpia si no están)
  cot            posicionamiento COT de la CFTC, si hay CSV disponible
  dxy            alineación o divergencia con el dólar
  noticias       calendario del puente, si gm_intel lo ha generado

Si una fuente externa falta, el compuesto se calcula con el resto y se declara
cuáles faltaban. Nunca se inventa un valor neutro silenciosamente: eso haría que
un compuesto incompleto pareciera completo.
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
import pandas as pd

#: Signo con el que cada componente entra en el compuesto. +1 significa que
#: valores altos del componente se leen como sentimiento ALCISTA para el oro.
#: Están declarados aquí, y no enterrados en el código, porque son la única
#: parte subjetiva del módulo y tienen que poder discutirse.
SIGNOS = {
    "tendencia": +1,     # precio alto en su rango = alcista
    "momento": +1,       # momento positivo = alcista
    "miedo": +1,         # el oro es refugio: más miedo = más demanda de oro
    "sesgo": +1,         # asimetría positiva = presión compradora
    "drawdown": +1,      # cerca de máximos = alcista (el valor es negativo)
    "expansion": 0,      # informativo: ni alcista ni bajista por sí mismo
    "estres": 0,         # informativo
    "sesiones": 0,       # informativo
    "intensidad": 0,     # informativo
    "cot": +1,           # más neto largo especulativo = alcista
    "dxy": +1,           # dólar débil = alcista para el oro
}


@dataclass
class SentimentConfig:
    trend_window: int = 60          # días para el rango de tendencia
    mom_window: int = 20
    vol_window: int = 21
    vol_hist: int = 504             # ~2 años para el percentil de volatilidad
    skew_window: int = 60
    dd_window: int = 252
    atr_fast: int = 14
    atr_slow: int = 100
    jump_window: int = 60
    jump_sd: float = 4.0
    z_clip: float = 3.0             # recorte de los z-scores
    external: dict = field(default_factory=dict)


def _z(s: pd.Series, window: int, clip: float) -> pd.Series:
    """z-score móvil: cada componente se normaliza por SU PROPIA historia.

    Sin esto, mezclar un ATR en dólares con una asimetría adimensional daría un
    compuesto dominado por la escala del componente más grande, no por su
    información.
    """
    mu = s.rolling(window, min_periods=max(10, window // 4)).mean()
    sd = s.rolling(window, min_periods=max(10, window // 4)).std()
    return ((s - mu) / sd.replace(0.0, np.nan)).clip(-clip, clip)


def internals(df: pd.DataFrame, cfg: SentimentConfig | None = None) -> pd.DataFrame:
    """Calcula los nueve internos derivados del precio, a frecuencia diaria.

    `df` necesita índice datetime y open/high/low/close (volume opcional). Si se
    le pasa una serie intradía, se agrega a días antes de calcular: los internos
    de sentimiento no tienen sentido barra a barra en H1.
    """
    cfg = cfg or SentimentConfig()
    d = df.copy()
    if not isinstance(d.index, pd.DatetimeIndex):
        raise ValueError("internals() exige un DatetimeIndex")

    # agrega a diario si viene intradía, conservando el perfil de sesión
    intradia = len(d) > 1 and (d.index[1] - d.index[0]) < pd.Timedelta("1D")
    hourly = d if intradia else None
    if intradia:
        agg = {"open": "first", "high": "max", "low": "min", "close": "last"}
        if "volume" in d.columns:
            agg["volume"] = "sum"
        cuenta = d["close"].resample("1D").count()
        d = d.resample("1D").agg(agg).dropna(subset=["close"])
        # Descarta el ultimo dia si esta a medias. Si no, `snapshot()` lee una
        # jornada incompleta: con solo horas asiaticas el interno de sesiones
        # marca −1.00 (z recortado a −3) y la lectura sale distorsionada justo
        # en la fila que mira el panel.
        if len(cuenta) > 1:
            tipico = float(cuenta.iloc[:-1].median() or 0.0)
            if tipico > 0 and float(cuenta.iloc[-1]) < 0.6 * tipico:
                d = d.iloc[:-1]
                hourly = hourly[hourly.index < d.index[-1] + pd.Timedelta("1D")]

    c, h, l = d["close"], d["high"], d["low"]
    r = np.log(c).diff() * 100.0
    out = pd.DataFrame(index=d.index)

    # tendencia: posición dentro del rango
    hi = h.rolling(cfg.trend_window, min_periods=10).max()
    lo = l.rolling(cfg.trend_window, min_periods=10).min()
    span = (hi - lo).replace(0.0, np.nan)
    out["tendencia"] = ((c - lo) / span * 2.0 - 1.0)        # −1..+1

    # momento normalizado por volatilidad (si no, el momento mide volatilidad)
    vol = r.rolling(cfg.vol_window, min_periods=5).std()
    out["momento"] = (r.rolling(cfg.mom_window, min_periods=5).sum()
                      / (vol * math.sqrt(cfg.mom_window)).replace(0.0, np.nan))

    # miedo: percentil de la volatilidad realizada en su propia historia
    out["miedo"] = vol.rolling(cfg.vol_hist, min_periods=60).rank(pct=True) * 2.0 - 1.0

    # sesgo realizado
    out["sesgo"] = r.rolling(cfg.skew_window, min_periods=20).skew()

    # drawdown respecto al máximo de la ventana (siempre ≤ 0)
    out["drawdown"] = (c / c.rolling(cfg.dd_window, min_periods=20).max() - 1.0) * 100.0

    # expansión: ATR corto frente a largo
    pc = c.shift(1)
    tr = pd.concat([h - l, (h - pc).abs(), (l - pc).abs()], axis=1).max(axis=1)
    atr_f = tr.rolling(cfg.atr_fast, min_periods=5).mean()
    atr_s = tr.rolling(cfg.atr_slow, min_periods=20).mean()
    out["expansion"] = (atr_f / atr_s.replace(0.0, np.nan)) - 1.0

    # estrés: frecuencia de saltos recientes
    sd = r.rolling(cfg.vol_window, min_periods=5).std()
    salto = (r.abs() > cfg.jump_sd * sd).astype(float)
    out["estres"] = salto.rolling(cfg.jump_window, min_periods=10).mean() * 100.0

    # intensidad de volumen
    if "volume" in d.columns and float(d["volume"].sum()) > 0:
        v = d["volume"].astype(float)
        out["intensidad"] = (v / v.rolling(cfg.atr_slow, min_periods=20)
                             .median().replace(0.0, np.nan)) - 1.0
    else:
        out["intensidad"] = np.nan

    # dominancia de sesión: solo si tenemos intradía de verdad
    if hourly is not None:
        hr = (np.log(hourly["close"]).diff() * 100.0).abs()
        hh = hourly.index.hour
        ny = pd.Series(np.where(hh >= 13, hr, 0.0), index=hourly.index)
        asia = pd.Series(np.where(hh < 7, hr, 0.0), index=hourly.index)
        tot = hr.resample("1D").sum().replace(0.0, np.nan)
        out["sesiones"] = ((ny.resample("1D").sum() - asia.resample("1D").sum())
                           / tot).reindex(out.index)
    else:
        out["sesiones"] = np.nan

    return out


def load_cot(path: str | Path, oi_normalise: bool = True) -> pd.DataFrame:
    """Carga un CSV de posicionamiento COT de la CFTC y lo deja listo.

    Normaliza por interés abierto por defecto, y no es un detalle: 300.000
    contratos netos NO significan lo mismo con un interés abierto de 200.000
    que de 600.000. Sin normalizar, la serie mide sobre todo el crecimiento del
    mercado a lo largo de 40 años, no el posicionamiento.

    AVISO sobre la fuente: los ficheros públicos de "GOLD" de la CFTC mezclan
    varios contratos (COMEX 088691, International Monetary Market, y el de 100
    onzas del CBOT). Si tu CSV trae una columna de contrato o de código, fíltralo
    a COMEX 088691 antes de usarlo: sin filtrar salen fechas duplicadas y el
    interés abierto se vuelve incoherente.
    """
    df = pd.read_csv(path)
    col_date = next((c for c in df.columns
                     if c.strip().lower() in ("date", "fecha", "report_date")), None)
    if col_date is None:
        raise ValueError(f"{Path(path).name}: no encuentro columna de fecha")
    df[col_date] = pd.to_datetime(df[col_date], errors="coerce")
    df = df.dropna(subset=[col_date]).set_index(col_date).sort_index()

    net = next((c for c in df.columns if "net" in c.lower()), None)
    if net is None:
        lg = next((c for c in df.columns if "long" in c.lower()), None)
        sh = next((c for c in df.columns if "short" in c.lower()), None)
        if lg and sh:
            df["NonComm_Net"] = pd.to_numeric(df[lg], errors="coerce") - \
                                pd.to_numeric(df[sh], errors="coerce")
            net = "NonComm_Net"
        else:
            raise ValueError(f"{Path(path).name}: ni columna neta ni long/short")

    out = pd.DataFrame(index=df.index)
    val = pd.to_numeric(df[net], errors="coerce")
    oi = next((c for c in df.columns
               if "open" in c.lower() and "interest" in c.lower()), None)
    if oi_normalise and oi:
        oi_v = pd.to_numeric(df[oi], errors="coerce").replace(0.0, np.nan)
        out["cot_net"] = val / oi_v
    else:
        out["cot_net"] = val
    return out.dropna()


def attach_external(ints: pd.DataFrame, cot: pd.DataFrame | None = None,
                    dxy: pd.DataFrame | None = None,
                    cfg: SentimentConfig | None = None) -> tuple[pd.DataFrame, list[str]]:
    """Añade las fuentes externas disponibles. Devuelve (datos, faltantes).

    No rellena las que falten: devuelve su nombre en `faltantes` para que el
    compuesto declare con qué se calculó. Un compuesto incompleto que se
    presenta como completo es peor que no tenerlo.
    """
    cfg = cfg or SentimentConfig()
    out = ints.copy()
    faltan: list[str] = []

    # COT: neto especulativo, normalizado por su propia historia
    if cot is not None and len(cot):
        col = next((c for c in cot.columns
                    if "net" in c.lower() or "neto" in c.lower()), None)
        if col is None:
            num = cot.select_dtypes("number")
            col = num.columns[0] if len(num.columns) else None
        if col is not None:
            s = pd.Series(cot[col].astype(float).to_numpy(),
                          index=pd.DatetimeIndex(cot.index).tz_localize(None).normalize())
            # el COT es semanal y se publica con retardo: se desplaza para no
            # usar informacion que el viernes todavia no era publica
            out["cot"] = s.reindex(out.index).ffill(limit=10).shift(1)
        else:
            faltan.append("cot")
    else:
        faltan.append("cot")

    # DXY: su retorno con signo invertido (dólar débil = alcista para el oro)
    if dxy is not None and len(dxy) and "close" in dxy.columns:
        s = pd.Series(dxy["close"].astype(float).to_numpy(),
                      index=pd.DatetimeIndex(dxy.index).tz_localize(None).normalize())
        rd = (np.log(s).diff() * 100.0).rolling(5, min_periods=2).sum()
        out["dxy"] = (-rd).reindex(out.index)
    else:
        faltan.append("dxy")

    return out, faltan


def composite(data: pd.DataFrame, cfg: SentimentConfig | None = None) -> pd.DataFrame:
    """Compuesto de sentimiento en −100..+100, con sus componentes en z.

    Solo entran los componentes con signo distinto de cero: los marcados con 0
    en `SIGNOS` son informativos (describen el estado) y no tienen una lectura
    alcista o bajista defendible, así que sumarlos sería inventar.
    """
    cfg = cfg or SentimentConfig()
    zs = pd.DataFrame(index=data.index)
    usados = []
    for name, signo in SIGNOS.items():
        if name not in data.columns:
            continue
        col = data[name]
        if col.notna().sum() < 60:
            continue
        zs[f"z_{name}"] = _z(col, cfg.vol_hist, cfg.z_clip)
        if signo != 0:
            zs[f"c_{name}"] = zs[f"z_{name}"] * signo
            usados.append(name)
    if not usados:
        raise ValueError("ningun componente utilizable para el compuesto")
    cols = [f"c_{n}" for n in usados]
    # media de los disponibles en cada fecha: una fuente que empieza tarde no
    # debe anular todo el historico previo
    bruto = zs[cols].mean(axis=1, skipna=True)
    zs["compuesto"] = (bruto / cfg.z_clip * 100.0).clip(-100, 100)
    zs["n_componentes"] = zs[cols].notna().sum(axis=1)
    zs.attrs["componentes_usados"] = usados
    return zs


def etiqueta(valor: float) -> str:
    """Traduce el compuesto a una etiqueta legible."""
    if not np.isfinite(valor):
        return "sin datos"
    if valor >= 50:
        return "euforia (riesgo de agotamiento)"
    if valor >= 20:
        return "alcista"
    if valor > -20:
        return "neutral"
    if valor > -50:
        return "bajista"
    return "capitulacion (riesgo de rebote)"


def validate(ints_or_data: pd.DataFrame, gold_daily: pd.DataFrame,
             horizons=(1, 5, 20), split: float = 0.70,
             cfg: SentimentConfig | None = None) -> dict:
    """¿El compuesto anticipa al oro? Medido fuera de muestra.

    Es la sección que convierte esto en algo defendible. Se ajusta el signo del
    compuesto en el primer tramo y se mide el acierto direccional en el segundo.
    Un acierto cercano al 50 % significa que el índice DESCRIBE el estado del
    mercado pero no lo anticipa, que es el resultado honesto esperado para
    cualquier indicador construido con el propio precio.
    """
    comp = (ints_or_data["compuesto"] if "compuesto" in ints_or_data.columns
            else composite(ints_or_data, cfg)["compuesto"])
    c = pd.Series(gold_daily["close"].astype(float).to_numpy(),
                  index=pd.DatetimeIndex(gold_daily.index).tz_localize(None).normalize())
    c = c.groupby(level=0).last()
    comp = comp.groupby(level=0).last()
    j = pd.DataFrame({"s": comp}).join(pd.DataFrame({"c": c}), how="inner").dropna()

    out = {"n_obs": int(len(j))}
    for H in horizons:
        fwd = (np.log(j["c"].shift(-H)) - np.log(j["c"])) * 100.0
        d = pd.DataFrame({"s": j["s"], "y": fwd}).dropna()
        if len(d) < 300:
            continue
        cut = int(len(d) * split)
        tr, te = d.iloc[:cut], d.iloc[cut:]
        # el signo con el que el compuesto se relaciona con el futuro, APRENDIDO
        # en el tramo de entrenamiento: fijarlo a mano seria mirar el resultado
        signo = 1.0 if float(tr["s"].corr(tr["y"]) or 0.0) >= 0 else -1.0
        hit = float((((te["s"] * signo) > 0) == (te["y"] > 0)).mean())
        se = math.sqrt(0.25 / len(te))
        out[f"h{H}"] = {
            "n_test": int(len(te)),
            "corr_train": round(float(tr["s"].corr(tr["y"]) or 0.0), 4),
            "corr_test": round(float(te["s"].corr(te["y"]) or 0.0), 4),
            "signo_aprendido": signo,
            "acierto_pct": round(100.0 * hit, 2),
            "sigmas_sobre_azar": round((hit - 0.5) / se, 2),
        }
    mejor = max((v["sigmas_sobre_azar"] for k, v in out.items()
                 if isinstance(v, dict)), default=0.0)
    out["veredicto"] = (
        f"hay senal (max {mejor:.2f} sigma): verificar estabilidad interanual "
        f"antes de usarla" if mejor > 2.0 else
        f"sin capacidad predictiva (max {mejor:.2f} sigma). El indice DESCRIBE "
        f"el estado del mercado, no lo anticipa. Usalo como contexto, no como "
        f"senal de entrada")
    return out


def snapshot(df: pd.DataFrame, cot: pd.DataFrame | None = None,
             dxy: pd.DataFrame | None = None,
             cfg: SentimentConfig | None = None) -> dict:
    """Estado de sentimiento HOY, listo para el panel."""
    cfg = cfg or SentimentConfig()
    ints = internals(df, cfg)
    data, faltan = attach_external(ints, cot, dxy, cfg)
    zs = composite(data, cfg)
    last = zs.iloc[-1]
    val = float(last["compuesto"])
    comps = {n: (None if not np.isfinite(last.get(f"z_{n}", np.nan))
                 else round(float(last[f"z_{n}"]), 2))
             for n in SIGNOS if f"z_{n}" in zs.columns}
    return {
        "fecha": str(zs.index[-1].date()),
        "compuesto": round(val, 1),
        "etiqueta": etiqueta(val),
        "componentes_z": comps,
        "componentes_usados": zs.attrs.get("componentes_usados", []),
        "n_componentes": int(last.get("n_componentes", 0) or 0),
        "fuentes_ausentes": faltan,
        "aviso": ("Indice derivado del PRECIO (mas las fuentes externas "
                  "disponibles). Describe el estado del mercado; su capacidad "
                  "predictiva esta medida en validate() y hay que consultarla "
                  "antes de operar con esto."),
    }


__all__ = ["SentimentConfig", "SIGNOS", "internals", "attach_external",
           "composite", "validate", "snapshot", "etiqueta", "load_cot"]
