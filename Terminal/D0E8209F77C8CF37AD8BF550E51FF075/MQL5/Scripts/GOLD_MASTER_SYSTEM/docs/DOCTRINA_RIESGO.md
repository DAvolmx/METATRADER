# Doctrina de riesgo

Cómo decide este sistema cuánto arriesgar, y por qué a veces decide **no operar**.

Implementación: [`python/live/gm_guardian.py`](../python/live/gm_guardian.py) y su
espejo en MT5 [`Include/GoldMaster/GoldMaster_Guardian.mqh`](../../../Include/GoldMaster/GoldMaster_Guardian.mqh).

---

## El principio

No hay ventaja direccional mecánica demostrada en este sistema
([HALLAZGOS.md](HALLAZGOS.md), secciones 1-3). Por tanto el tamaño de la
posición **no** se deduce de una confianza en la señal: se deduce de la
volatilidad actual y de lo que puedes perder sin quedarte fuera del juego.

Esto invierte el orden habitual. No es «tengo una señal buena, arriesgo más». Es
«esto es lo máximo que puedo arriesgar; ¿cabe la operación dentro?». Si no cabe,
no se opera.

## La escalera de capital

Pensada para el objetivo que planteaste: capitalizar una cuenta de 10 $ hasta 50 $
operando despacio, y solo después acelerar.

| Etapa | Capital | Riesgo/operación | Objetivo diario | Stop diario | Máx. operaciones/día |
|---|---|---|---|---|---|
| semilla | 0 – 25 $ | 3,0 % | 2 $ | 1,5 $ | 3 |
| construir | 25 – 50 $ | 3,5 % | 4 $ | 2,5 $ | 4 |
| acelerar | 50 $ + | 6,0 % | 12 $ | 8 $ | 6 |

Lógica de los dos límites diarios, que es la parte que la gente se salta:

- **Objetivo diario alcanzado → se para.** Ganar 2 $ y seguir operando es
  devolver esos 2 $ al mercado con probabilidad alta. El guardián bloquea.
- **Stop diario alcanzado → se para.** Es el corte que impide que un día malo
  se convierta en el día que te saca del juego.

El stop diario es siempre **menor** que el objetivo. No es un error: perder
duele más que ganar cuando el capital es pequeño, porque la recuperación
porcentual necesaria crece más rápido que la pérdida.

## El suelo de lote mínimo: el hallazgo que condiciona todo

Este es el resultado más importante de toda la gestión de capital, y es
aritmético, no opinable.

Con **cuenta micro** y 10 $ de capital, el lote mínimo de XAUUSD obliga a
arriesgar **más del 50 % de la cuenta** en una sola operación con un stop
razonable. No es una cuestión de disciplina: es que el instrumento no admite una
posición tan pequeña.

El guardián lo comprueba antes de cada orden y **bloquea**, con el mensaje
concreto de cuánto exigiría el lote mínimo frente a lo que tienes:

```
ni el lote minimo cabe (arriesga 5.20 > 50% de 10.00):
usa cuenta cent o mas capital
```

Las dos salidas reales:

1. **Cuenta cent**, donde el valor del lote mínimo es 100 veces menor. Medido en
   simulación: la probabilidad de llegar a 50 $ pasa a ser alta, frente al 72 %
   de **ruina** en micro con 10 $.
2. **Capitalizar primero** hasta que el lote mínimo represente un riesgo
   admisible.

Cualquier sistema que te deje operar oro con 10 $ en micro sin avisarte de esto
te está ocultando el único número que decide tu supervivencia.

## Los bloqueos

El guardián deniega la operación, sin negociación posible, si:

| Condición | Razón |
|---|---|
| Tope diario de operaciones alcanzado | La sobreoperación es el modo de fallo más común |
| Objetivo diario alcanzado | Guarda la ganancia y para |
| Stop diario alcanzado | Protección del capital |
| Régimen **agitado** | Medido: −0,17R histórico en ese régimen |
| Noticia de alto impacto en < 30 min | El spread se abre y el stop deja de valer |
| Spread por encima del máximo | El coste se come la operación |
| El lote mínimo no cabe | Ver arriba |
| Stop inválido o nulo | Operar sin stop no es operar |

## Dimensionado

```
riesgo_objetivo = etapa.riesgo_pct × capital
lote            = redondear(riesgo_objetivo / (distancia_stop × usd_por_precio))
lote            = max(lote, lote_mínimo)
```

y después, mientras el riesgo resultante supere el máximo admisible, se **baja**
el lote escalón a escalón. Si al llegar al mínimo sigue sin caber, se bloquea.

La distancia del stop sale de la volatilidad **de ahora** (ATR o la σ condicional
del modelo), no de una media histórica. El agente de régimen
([`gm_agents.py`](../python/agents/gm_agents.py)) publica esa cifra en cada ciclo.

## Probabilidad de ruina medida

Bootstrap por bloques, 20.000 remuestreos. Por bloques y no i.i.d. a propósito:
las operaciones llegan agrupadas en los mismos tramos de mercado, y un bootstrap
independiente rompería esa agrupación y **subestimaría** el drawdown.

| Riesgo/operación | Prob. de ruina | Drawdown mediano | Capital final p50 |
|---|---|---|---|
| 1 % | 0,0 % | −7,8 % | ×1,22 |
| 2 % | 0,0 % | −15,1 % | ×1,46 |
| 5 % | **2,7 %** | **−34,6 %** | ×2,25 |

Advertencia sobre esta tabla: está calculada sobre una serie de operaciones cuya
esperanza positiva **no sobrevive** la corrección por pruebas múltiples
(p = 0,847). Es decir, los capitales finales de la última columna son optimistas
porque suponen que ese edge existe. Las columnas de **ruina y drawdown** sí son
útiles, porque describen la dispersión del proceso independientemente de la
esperanza.

## Doble implementación, un solo criterio

La misma lógica vive en dos sitios y eso es deliberado:

- **Python** (`gm_guardian.py`) para el panel, el diario y la investigación.
- **MQL5** (`GoldMaster_Guardian.mqh`) **dentro del EA**, porque un EA que opera
  solo en MT5 no puede depender de que un servicio Python esté levantado.

Para que no divergan, el lado Python escribe `guardian.txt` en el sandbox común
y el EA lo lee con `SyncFromBridge()`. Una divergencia entre ambos significaría
que el EA opera con reglas distintas de las que tú ves en el panel, y eso es
exactamente el tipo de fallo silencioso que arruina cuentas.

## El diario, y por qué importa más que el backtest

El gobernador registra cada operación con su contexto (régimen, sesión, spread,
escenario del bloque, resultado en R). Con suficientes operaciones,
`learn_from_journal()` entrena un modelo sobre **tus** datos.

Esto es cualitativamente distinto de un backtest: mide **tu** operativa real, con
tu broker, tu latencia, tus horarios y tus decisiones discrecionales. Es la única
fuente de ventaja que no está sujeta al sesgo de selección múltiple de un
barrido, porque no hay barrido: hay un registro.

Por debajo de 20 operaciones el agente del diario se niega explícitamente a
concluir nada, y hace bien.
