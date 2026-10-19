# Hallazgos — qué dice la evidencia

Registro de todo lo que este sistema ha **medido**, con los números y el método.
Está escrito para que puedas discutirlo, reproducirlo o refutarlo, no para
convencerte de nada.

Regla de la casa: aquí solo entran resultados medidos sobre datos reales con un
protocolo declarado. Una idea sin medición no es un hallazgo, es una corazonada.

**Datos base.** Oro XAUUSD H1, 122.027 velas reales, 2004-06-11 → 2025-06-06
(21,0 años). DXY diario, 6.960 observaciones, 1999-01-04 → 2026-10-02,
construido con la fórmula oficial de ICE y los 6 componentes completos a partir
de los tipos H.10 de la Reserva Federal; validado contra niveles históricos
conocidos (mínimo 71,26 en marzo 2008, máximo 113,97 en septiembre 2022).

---

## 1. No hay ventaja direccional mecánica. Esto está cerrado.

| Prueba | Resultado |
|---|---|
| AUC direccional de la ecuación maestra, en muestra | **0,4900** |
| AUC direccional, fuera de muestra (2020-2025) | **0,4980** |
| Acierto direccional del catálogo de estrategias | 49,7 % – 50,5 % |

Un AUC de 0,50 es el azar. El modelo reproduce con precisión la **estructura de
riesgo** del oro y no tiene **ninguna** capacidad de anticipar la dirección. Eso
no es un defecto de la calibración: es una propiedad del activo a esta
frecuencia, y se ha medido tanto dentro como fuera de muestra.

## 2. Los order blocks no superan la corrección por pruebas múltiples

Se construyó la taxonomía SMC completa (5 escenarios × atributos ortogonales ×
3 refinamientos de zona) y se detectaron **1.395 bloques** en 21 años: classic
551, breaker 394, rejection 233, propulsion 137, mitigation 80.

Después se barrieron **486 especificaciones** de estrategia con fills realistas
(spread y deslizamiento descontados; stop antes que objetivo cuando una barra
toca ambos), con corte train/test por fecha en 2019-03.

| Prueba | Resultado |
|---|---|
| Mejor esperanza en train | +0,3793 R (`eq·eq·tp3R·breaker·ext`, n=58) |
| Estadístico t de esa mejor | **1,51** — no significativo |
| Especificaciones con esperanza > 0 | 110 de 300 con n≥30 |
| De las 10 mejores de train, en test | 4 se dan la vuelta a negativo |
| **Contraste de realidad de White** | **p = 0,847** |

El contraste de White remuestrea por bloques **sobre los order blocks**, no sobre
cada estrategia por separado, para conservar la correlación entre variantes que
operan los mismos bloques. Con p = 0,847, la mejor de 486 variantes es
exactamente lo que cabe esperar de barrer un espacio grande sobre una serie
finita.

## 3. El test nulo sintético: hay volatilidad, no estructura institucional

Esta es la prueba más severa y la que de verdad contesta si los order blocks
leen huella institucional.

Se generaron caminos de oro con la ecuación maestra calibrada —que por
construcción **no contiene ninguna estructura institucional**, solo volatilidad
agrupada, colas y regímenes— y se corrió sobre ellos el detector completo y el
mismo barrido de 486 especificaciones.

El generador se validó antes de usarlo como referencia: razón de amplitud
intrabarra 2,191 frente a 2,200 real, volatilidad 17,4 % frente a 17,99 %,
**ACF(|r|) rezago 1 idéntica a 0,267**, coherencia OHLC 100 %.

| Resultado | Valor |
|---|---|
| Order blocks detectados en datos **sintéticos** | ~1.410 por camino (vs 1.022 reales) |
| Mejor esperanza sintética, mediana | **+0,600 R** |
| Mejor esperanza sintética, percentil 90 | +0,852 R |
| Mejor esperanza sintética, máximo | +1,286 R |
| Mejor esperanza **real** | +0,379 R |
| Caminos sintéticos que **superan** el mejor real | **96,4 %** |
| **p-valor del test nulo** | **0,964** |

Léelo despacio: sobre datos donde por construcción no hay dinero institucional,
el detector encuentra **más** order blocks que en el oro real, y el barrido saca
**mejor** resultado nueve de cada diez veces. Lo que mide el detector es cosecha
de volatilidad.

**Campaña completa**: 84 caminos nulos (la campaña se detuvo en 84 de 140 por un
reinicio del contenedor; el p-valor se mantuvo estable desde el camino 12 —
91,7 %, 96,5 %, 95,7 %, 96,4 %— así que más caminos no cambian la conclusión).
Artefactos reproducibles en `python/smc/out_campaign/`.

### Y tampoco se puede saber de antemano cuál funcionará

Última defensa posible: aunque la media no tenga ventaja, ¿se puede aprender a
distinguir los order blocks buenos de los malos? Se entrenó un clasificador
sobre las 15 características del bloque y su contexto (fuerza del
desplazamiento, barrido previo, FVG, posición en el rango, sesión, volumen,
escenario), con validación walk-forward **purgada** (hueco de 24 barras entre
entrenamiento y validación para que no haya solape).

| Pliegue | 1 | 2 | 3 | 4 | Medio |
|---|---|---|---|---|---|
| AUC | 0,300 | 0,383 | 0,534 | 0,487 | **0,426** |

AUC medio **0,426**, por debajo del azar. Sobre 569 operaciones con una tasa
base de acierto del 35,3 %. Un AUC sistemáticamente inferior a 0,5 fuera de
muestra es la firma del sobreajuste: el modelo aprende patrones del tramo de
entrenamiento que se invierten en el de validación.

No hay forma de saber de antemano qué order block va a funcionar.

> Durante el desarrollo del generador apareció un sesgo propio que invalidaba
> esta comparación: el puente browniano escalaba la mecha con el cuerpo de la
> vela, de modo que era estructuralmente incapaz de producir velas de rechazo
> (1 bloque sintético frente a 169 reales). Al desacoplarlo y escalar con la
> volatilidad local, los cinco escenarios aparecen en proporciones comparables
> (rechazo 150 vs 169) y el nulo pasa a ser justo. Sin ese arreglo, el test
> habría "demostrado" una ventaja que era un artefacto del generador.

## 4. El efecto del dólar: la única señal con significación real, e inestable

| Modelo (predecir el oro de mañana) | R² fuera de muestra | Acierto | σ sobre azar |
|---|---|---|---|
| Solo retardos del oro | **−0,00046** | 53,96 % | 3,13 |
| **Solo DXY** | **+0,00213** | **55,17 %** | **4,09** |
| Oro + DXY | +0,00162 | 54,85 % | 3,84 |

La ablación es imprescindible: sin ella, el 55 % era ininterpretable. Dice que el
efecto es **del dólar** —el modelo de solo oro tiene R² negativo, es peor que
predecir la media— y que añadir retardos del oro **empeora**.

No hay look-ahead: el DXY es el fijado de mediodía en Nueva York (17:00 UTC) y se
predice el cierre del día siguiente, unas 30 horas después.

**Y aquí está el problema**, que es lo que cualquiera te vendería escondido:

| Año | 2019 | 2020 | 2021 | 2022 | 2023 | 2024 | 2025 |
|---|---|---|---|---|---|---|---|
| Acierto | 55,3 % | 59,8 % | **49,6 %** | **50,6 %** | 53,6 % | 55,2 % | 66,4 %* |

\* n=107 días, muestra pequeña.

**Dos años consecutivos sin ningún efecto.** El Sharpe neto agregado es 0,93,
pero el agregado esconde que la señal desaparece durante años enteros. Quien la
dimensione con la media pasará esos años plano o perdiendo. Es una línea de
investigación prometedora, no un sistema.

## 5. Oro y dólar: la cobertura se rompe cuando se necesita

| Medida | Valor |
|---|---|
| Correlación global de retornos diarios | **−0,379** |
| Móvil a 252 días | media −0,390, desviación 0,105, rango [−0,68, −0,14] |
| Correlación en régimen calmo | −0,447 |
| Correlación en régimen **agitado** | **−0,364** |
| Días en que oro y dólar suben **juntos** | **19,7 %** |
| Beta móvil del oro al dólar | mediana −0,86, rango [−1,91, −0,25], negativa el 100 % |
| Cointegración (Engle-Granger) | **NO** cointegrados, ADF p = 0,244 |
| Pico de correlación cruzada | **rezago 0** |

Tres consecuencias prácticas:

1. El **signo** de la relación es notablemente estable (la beta a 252 días es
   negativa el 100 % del tiempo), pero la **magnitud** varía ocho veces. Usar
   una beta constante para cubrir es un error.
2. La correlación **se debilita** en los tramos agitados, que es justo cuando se
   buscaría la cobertura. Casi uno de cada cinco días suben los dos a la vez:
   oro y dólar compiten como refugio.
3. Al **no** estar cointegrados, operar "la vuelta a la relación normal" entre
   oro y dólar no tiene base estadística. El pico en rezago 0 confirma que
   ninguno de los dos adelanta al otro de forma aprovechable.

## 6. El sentimiento describe el estado; no lo anticipa

Se construyó un índice con nueve internos derivados del precio (tendencia,
momento, miedo, sesgo, drawdown, expansión, estrés, sesiones, intensidad) más
las fuentes externas disponibles, cada componente normalizado por su propia
historia.

| Horizonte | Acierto fuera de muestra | σ sobre azar |
|---|---|---|
| 1 día | 50,66 % | +0,53 |
| 5 días | 48,86 % | −0,91 |
| 20 días | 48,41 % | −1,26 |

Sin capacidad predictiva. Es el resultado esperado y honesto: un índice
construido con el precio es, por definición, una función del precio. Sirve como
**contexto** —saber si el mercado está en miedo o en complacencia, y que eso
signifique siempre lo mismo— no como señal de entrada.

## 7. El posicionamiento COT tampoco predice

40 años de Commitments of Traders de la CFTC (1986-01 → 2026-10, 1.938
observaciones semanales del contrato COMEX 088691), validados contra una
segunda fuente independiente con **170/170 coincidencias exactas** en las
semanas solapadas.

El neto no comercial se normaliza por interés abierto, porque 300.000 contratos
netos no significan lo mismo con un interés abierto de 200.000 que de 600.000.

| Variable | Horizonte | Acierto | σ |
|---|---|---|---|
| neto/OI (z) | 1 semana | 53,85 % | +1,44 |
| neto/OI (z) | 4 semanas | 54,13 % | +1,55 |
| neto/OI (z) | 12 semanas | 53,28 % | +1,23 |
| variación | 4 semanas | 52,99 % | +1,12 |

Ninguno alcanza los 2σ. Y hay una señal de alarma más clara que el σ: la
correlación entre posicionamiento y retorno futuro **cambia de signo** entre el
tramo de entrenamiento y el de prueba (−0,015 → +0,009 a una semana; −0,001 →
+0,141 a doce). Una relación que invierte su signo entre periodos no es una
relación: es ruido con buena prensa.

Añadir el COT al compuesto de sentimiento **empeora** su acierto (de +0,53σ a
−0,78σ a un día), lo que es coherente con que no aporte información.

> Trampa de los datos, documentada por si reutilizas la fuente: los ficheros
> públicos de "GOLD" de la CFTC mezclan tres contratos distintos (COMEX 088691,
> International Monetary Market, y el de 100 onzas del CBOT). Sin filtrar salen
> 120 fechas duplicadas y un interés abierto incoherente. `load_cot()` lo avisa.

## 8. El problema real nunca fue la señal: era el tamaño de la posición

Medido con bootstrap por bloques (20.000 remuestreos, que conserva la
agrupación temporal de las operaciones y por tanto no subestima el drawdown):

| Riesgo por operación | Probabilidad de ruina | Drawdown mediano |
|---|---|---|
| 1 % | 0,0 % | −7,8 % |
| 2 % | 0,0 % | −15,1 % |
| 5 % | **2,7 %** | **−34,6 %** |

Y el hallazgo estructural que condiciona todo lo demás: **con una cuenta de 10 $
en micro, el lote mínimo obliga a arriesgar más de lo admisible**. El gobernador
de riesgo lo bloquea con un mensaje explícito en vez de dejarte operar al 50 %
por operación. La vía es cuenta cent, o capitalizar antes de operar.

## 9. Límites conocidos de la ecuación maestra

Dicho aquí para que nadie los descubra con dinero puesto:

- **Curtosis simulada 36,4 frente a 24,3 real.** El modelo exagera los extremos
  puntuales.
- **Riesgo de mercado bajista plurianual mal capturado.** El −45 % real de
  2011-2015 es un fenómeno de *deriva* a escala de años, no de volatilidad. Con
  21 años (≈2 ciclos) no se puede estimar un proceso de deriva bi-régimen con
  honestidad. Por eso `simulate(drift_annual=0.0)` es obligatorio para trabajo
  de riesgo: la banda con β histórico hereda el viento de cola de 2004-2025.
- **Asimetría casi nula.** El oro no tiene el efecto apalancamiento de la renta
  variable: EGARCH ajusta mejor (ΔAIC 2.636) pero su γ = −0,009 es
  económicamente despreciable, así que no se adoptó.
- **El test KS rechaza siempre.** Con n = 122.027 observaciones, el contraste de
  Kolmogórov-Smirnov tiene potencia para rechazar cualquier familia paramétrica.
  Lo informativo es el ajuste de momentos y de cuantiles, no ese p-valor.
- **Autocorrelación residual.** Ljung-Box sobre los residuos estandarizados
  rechaza (p < 0,05): queda una componente lineal pequeña. No es aprovechable
  direccionalmente (AUC ≈ 0,49); probablemente microestructura a H1.

## 10. Lo que este sistema sí te da

Ninguna de estas cosas es una promesa de beneficio. Todas son útiles.

1. **Dimensionamiento honesto.** La distribución de drawdown y la probabilidad
   de ruina salen de un modelo cuya estructura de riesgo está validada contra
   21 años, con la banda neutral como referencia conservadora.
2. **Un detector de autoengaño.** Contraste de White, test nulo sintético, y el
   libro de pruebas múltiples de la bóveda, que endurece el umbral conforme
   investigas. Medido: el umbral pasó de p < 1,25e-02 a **p < 1,02e-04** en
   cuanto se registraron 486 pruebas. El sistema se vuelve más difícil de
   engañar con el tiempo.
3. **Contexto medido, no narrativa.** Régimen actual, volatilidad condicional,
   estado del dólar, taxonomía de los bloques presentes en pantalla.
4. **Un cuaderno que no olvida.** Cada experimento queda con su veredicto, y el
   agente crítico publica las contradicciones y lo que falta revalidar.

## Cómo reproducir todo esto

```bash
# 1. Calibrar y validar la ecuación (train/test sin solape)
python python/model/gm_calibrate.py DATOS_H1.csv --split 0.75 --out out_model

# 2. Campaña completa de order blocks: barrido + White + nulo sintético + ML
python python/smc/gm_ob_campaign.py DATOS_H1.csv out_model/params_xauusd_h1.json \
    --out out_campaign --null-paths 140 --budget-min 100

# 3. Ciclo de agentes, que deja todo registrado en la bóveda Obsidian
python python/agents/gm_lab.py --vault ~/GoldMasterVault \
    --gold DATOS_H1.csv --dxy DXY_d1.csv
```

Los datos no se versionan en el repositorio. `Scripts/DATOS/GM_ExportarHistorico.mq5`
exporta tu propio histórico desde MT5 al formato que lee `python/core/gm_data.py`.
