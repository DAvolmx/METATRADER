# La ecuación maestra del oro

Modelo estocástico de cuatro capas para el log-precio del XAUUSD, calibrado
sobre 122.027 velas horarias reales (2004-06-11 → 2025-06-06).

Implementación: [`python/model/gm_gold_sde.py`](../python/model/gm_gold_sde.py).
Calibración y validación: [`python/model/gm_calibrate.py`](../python/model/gm_calibrate.py).

---

## 1. Qué es y qué no es

Es una ecuación que reproduce la **estructura de riesgo** del oro: cómo se
agrupa su volatilidad, cuán gruesas son sus colas, cómo cambia de régimen, cómo
respira a lo largo del día y cómo se distribuyen sus drawdowns.

**No predice la dirección, y no lo pretende.** Está medido: AUC direccional
0,4900 en muestra y 0,4980 fuera de muestra, o sea el azar. Quien quiera una
fórmula que diga si el oro sube mañana no va a encontrarla aquí, y debería
desconfiar de quien se la ofrezca.

Para qué sirve entonces: para **dimensionar**. Si sabes cómo se distribuyen los
drawdowns de 21 años, puedes calcular tu probabilidad de ruina con un lote dado.
Eso es exactamente el cuello de botella real de una cuenta pequeña, y es un
problema resoluble, al contrario que adivinar la dirección.

## 2. La ecuación

$$
d\ln S_t = \mu_t\,dt + \sigma_t\,s(h_t)\,dW_t + J\,dN_t
$$

con la deriva total

$$
\mu_t = \underbrace{\beta}_{\text{L1 secular}}
      + \underbrace{\kappa\,(\bar\varepsilon - \varepsilon_t)}_{\text{L2 cíclica}}
      + \underbrace{m(R_t)}_{\text{régimen}}
      - \underbrace{\lambda(R_t)\,\mathbb{E}[e^J-1]}_{\text{compensador del salto}}
      - \underbrace{\tfrac{1}{2}\sigma_t^2 s^2(h_t)}_{\text{corrección de Itô}}
$$

### L1 — Tendencia secular

$$\ln S^*_t = \alpha + \beta t \qquad \alpha = 6{,}4333 \quad \beta = 0{,}06484$$

Ajuste por mínimos cuadrados con $t$ en años. R² = 0,743. La deriva secular es
de **+6,48 %/año** en log-precio.

### L2 — Desviación cíclica (Ornstein-Uhlenbeck)

$$\varepsilon_t = \ln S_t - \ln S^*_t \qquad d\varepsilon_t = -\kappa\,\varepsilon_t\,dt + \dots$$

$\kappa = 0{,}4776$ año⁻¹, **vida media 1,45 años**, estimado por AR(1) a
frecuencia diaria.

> **Advertencia que condiciona el uso de esta capa.** El contraste de
> Dickey-Fuller aumentado sobre $\varepsilon_t$ da **p = 0,263**: no se puede
> descartar que sea un paseo aleatorio. Por eso `simulate()` lleva
> `use_ou=False` por defecto. Activarla equivale a afirmar que el oro vuelve a
> su tendencia log-lineal, lo que inflaría los retornos simulados cuando el
> precio está por debajo y **maquillaría a la baja la probabilidad de ruina**.

### L3 — Volatilidad: GARCH(1,1) con colas y estacionalidad

$$\sigma_t^2 = \omega + a\,u_{t-1}^2 + b\,\sigma_{t-1}^2 \qquad u_t = \sigma_t z_t,\; z_t \sim t_\nu$$

| Parámetro | Valor |
|---|---|
| $\omega$ | 1,063 × 10⁻³ |
| $a$ | 0,0500 |
| $b$ | 0,9300 |
| persistencia $a+b$ | **0,9800** |
| $\nu$ (grados de libertad) | **4,4** |
| volatilidad incondicional | 0,2305 %/barra = **17,6 %/año** |

El multiplicador estacional $s(h)$ tiene 24 valores (uno por hora UTC),
estimados con **desviación absoluta mediana** y no con la varianza: un solo
salto de IPC distorsionaría la varianza de esa hora. Se normaliza a media
cuadrática 1, de modo que no altera la volatilidad global, solo la reparte.
El perfil resultante marca el solapamiento Londres-Nueva York (×1,83 a las
15:00 UTC) frente a la madrugada asiática (×0,47 a las 23:00).

### L4 — Saltos: picos sobre umbral con Pareto generalizada

Se marca salto donde $|\tilde r_t| > 4\,\hat\sigma_t$, y el **exceso** sobre el
umbral se ajusta con una Pareto generalizada, que es la distribución límite
correcta para excedencias (Pickands-Balkema-de Haan) y no una normal truncada
inventada.

$\lambda = 28{,}5$ saltos/año, exceso ~ GPD($\xi = 0{,}212$, $\beta = 0{,}288$ %),
53 % al alza.

### Regímenes de Markov

Tres estados estimados con un HMM gaussiano **a frecuencia diaria**:

| Régimen | Multiplicador σ | λ (saltos/año) | Frecuencia | Duración |
|---|---|---|---|---|
| calmo | ×0,66 | 10 | 45 % | 2 días |
| normal | ×0,86 | 31 | 32 % | 2 días |
| agitado | ×1,56 | 61 | 23 % | 12 días |

## 3. Tres defectos propios, encontrados y corregidos

Se documentan porque el proceso de depuración es parte del resultado, y porque
los tres eran invisibles desde la curva de ajuste.

### a) Doble conteo de colas

Ajustado sobre la serie cruda, el GARCH-t da $\nu = 4{,}4$, cuya curtosis
teórica es 18. Las colas de la Student-t **ya absorben los saltos**. Añadir
encima un proceso de Poisson los cuenta dos veces: curtosis simulada **50,9**
frente a **24,6** real.

Se intentó separar difusión y saltos winsorizando los extremos a ±4σ y
reajustando el GARCH sobre la serie limpia. **Resultó inestable**: la
winsorización crea masas puntuales artificiales justo en el umbral y el MLE se
va a un óptimo local absurdo ($\nu \to 188$, $a \to 0{,}55$, volatilidad
incondicional 65,8 %/año frente al 17,9 % real).

Solución adoptada: una sola pasada, y `include_jumps=False` por defecto, con la
capa de saltos estimada igualmente porque sirve para marcar barras, alimentar el
bloqueo por noticias y construir escenarios de estrés deliberados.

### b) Regímenes demasiado rápidos

Ajustando el HMM sobre barras horarias, la matriz de transición salía con
diagonal ≈0,96-0,97 **por hora**: duración esperada de 24-36 horas. Los
regímenes macro del oro duran meses — el mercado bajista 2011-2015 son cuatro
años.

Consecuencia medida: con regímenes de un día la simulación promediaba las épocas
tranquilas y las tensas, y el drawdown real de −45 % caía **fuera** de la banda
simulada [−32 %, −11 %].

Solución: HMM a frecuencia diaria, y `regime_bars` le dice al simulador que
conmute al mismo ritmo al que se estimó.

### c) Comparación de drawdown sesgada

El drawdown máximo **crece con la longitud del camino**. Se estaba comparando un
máximo real de 21 años contra caminos simulados de 1,5 años, lo que infravalora
el riesgo del modelo y lo hacía parecer peor de lo que es.

Solución: modo `stats_only=True`, que acumula drawdown, valor final y
volatilidad con memoria O(n_paths) en vez de O(n_paths × n_steps), y permite
simular a longitud real con decenas de miles de caminos.

Tras el arreglo, el −45,2 % real cae **dentro** de la banda simulada en las tres
columnas de validación.

## 4. Decisión descartada con evidencia: la asimetría

| Modelo | log-verosimilitud | AIC | ν | γ |
|---|---|---|---|---|
| GARCH(1,1)-t | 36.811,0 | −73.611,9 | 4,38 | — |
| GJR-GARCH-t | **no converge** | — | — | — |
| EGARCH-t | **38.129,8** | **−76.247,5** | 3,73 | −0,0092 |

EGARCH ajusta mejor de forma decisiva (ΔAIC = 2.636), pero su parámetro de
asimetría es **γ = −0,0092**: económicamente despreciable. El oro **no** tiene
el efecto apalancamiento de la renta variable — es un refugio que puede
dispararse en ambos sentidos. Se mantiene GARCH(1,1)-t por simplicidad del
simulador, y la asimetría residual (−0,24 de sesgo real) se atribuye a la
componente de eventos, no a la volatilidad.

## 5. Validación

Protocolo: calibrar **solo** con 2004-2020, validar en 2020-2025 nunca vistos, y
recalibrar con todo para producción.

| Métrica | En muestra | Fuera de muestra | Completo |
|---|---|---|---|
| Volatilidad anual real | 17,88 % | 15,04 % | 17,22 % |
| Volatilidad anual **simulada** | 18,42 % | 18,57 % | **17,39 %** |
| Curtosis real | 24,59 | 19,04 | 24,32 |
| Curtosis simulada | 32,74 | 32,90 | 38,06 |
| ACF(\|r\|) rezago 1 real | 0,272 | 0,247 | 0,269 |
| ACF(\|r\|) rezago 1 **simulada** | 0,253 | 0,253 | **0,258** |
| ACF(\|r\|) rezago 24 real / simulada | 0,190 / 0,220 | 0,130 / 0,219 | 0,181 / 0,221 |
| Ljung-Box sobre z² | 0,0000 | **0,9997** | 0,0000 |
| **AUC direccional** | **0,5057** | **0,4980** | **0,4900** |
| Drawdown real | −45,2 % | −21,9 % | −45,2 % |
| Banda simulada p05–p95 | [−66,5, −30,5] | [−54,9, −20,6] | [−48,4, −23,9] |
| ¿Real dentro de la banda? | **sí** | **sí** | **sí** |

Lo que se lee aquí:

- **El agrupamiento de volatilidad se reproduce con precisión** (ACF 0,258 vs
  0,269) y el nivel de volatilidad casi exactamente (17,39 % vs 17,22 %).
- **Ljung-Box sobre z² da p = 0,9997 fuera de muestra**: el GARCH eliminó la
  autocorrelación de la volatilidad en datos no vistos. Es el éxito más limpio
  de la calibración.
- **La curtosis sigue alta** (38 vs 24): el modelo exagera los extremos.
- **El AUC direccional es 0,49-0,50 en las tres columnas.** Robusto y rotundo.

### Para dimensionar: usa la banda neutral

| Banda de drawdown (modelo completo) | p50 | p05 | p01 |
|---|---|---|---|
| Con β histórico (+6,48 %/año) | −33,7 % | −48,4 % | — |
| **Con β = 0 (neutral)** | **−39,2 %** | **−58,9 %** | **−66,9 %** |

La banda con β histórico hereda el viento de cola de 2004-2025. Para trabajo de
riesgo hay que pasar `drift_annual=0.0`: ninguna realización con deriva positiva
permanente reproduce con probabilidad apreciable un bajista plurianual como el
de 2011-2015.

## 6. Uso

```python
from gm_gold_sde import calibrate, simulate, validate, GoldSDE
import gm_data

df = gm_data.load("XAUUSD_H1.csv")
m, diag = calibrate(df)
print(m.equation_text())

# riesgo: deriva neutral, sin saltos, modo streaming a longitud real
st = simulate(m, n_paths=20_000, n_steps=len(df),
              drift_annual=0.0, stats_only=True)
print("drawdown p05:", np.percentile(st["max_dd"], 5) * 100)

m.to_json("params_xauusd_h1.json")
m2 = GoldSDE.from_json("params_xauusd_h1.json")
```

Banderas que importan y por qué están donde están:

| Bandera | Por omisión | Razón |
|---|---|---|
| `use_ou` | `False` | El ADF (p=0,263) no descarta paseo aleatorio |
| `include_jumps` | `False` | El GARCH-t ya lleva las colas (curtosis 51 vs 25) |
| `drift_annual` | `None` (β ajustado) | Pasa `0.0` para todo trabajo de riesgo |
| `stats_only` | `False` | Pásalo a `True` para simular a longitud real |
| `antithetic` | `True` | Reduce varianza del estimador sin sesgarlo |

## 7. Qué haría falta para mejorarla

Por orden de valor esperado, y siendo honesto sobre la dificultad:

1. **Deriva bi-régimen a escala plurianual** (toro/oso con persistencia de
   años). Es el defecto más importante que queda. Con 21 años hay ≈2 ciclos: no
   es estimable con honestidad. Harían falta datos de oro anteriores a 2004.
2. **Memoria larga en la volatilidad** (FIGARCH o HAR). El GARCH(1,1) decae
   demasiado rápido: ACF a rezago 120 simulada 0,139 frente a 0,086 real.
3. **Variables exógenas en la deriva**: tipos reales, DXY, flujos de ETF. El
   módulo [`gm_dxy.py`](../python/model/gm_dxy.py) ya mide el dólar, y lo que
   encuentra es una señal con significación real (4,09σ) pero **inestable año a
   año** — ver [HALLAZGOS.md](HALLAZGOS.md), sección 4.
4. **Calibración sobre el símbolo del broker**, no sobre un proxy: el spread, el
   horario y los huecos de Deriv forman parte del resultado.
   `Scripts/DATOS/GM_ExportarHistorico.mq5` exporta tu propio histórico.
