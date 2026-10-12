# Copyright 2026, MetaQuotes Ltd.
# https://www.mql5.com

from datetime import datetime, timedelta
import MetaTrader5 as mt5
import tensorflow as tf
import numpy as np
import matplotlib.pyplot as plt
from sklearn.preprocessing import MinMaxScaler
import pandas as pd

# Inicializar MetaTrader 5
if not mt5.initialize():
    print("Error: No se pudo inicializar MT5")
    mt5.shutdown()
    exit(1)

print("MT5 inicializado correctamente")

# Obtener información de la cuenta
account_info = mt5.account_info()
if account_info is not None:
    print(f"Cuenta: {account_info.login}, Balance: {account_info.balance:.2f}")

# Definir símbolo y timeframe para el ORO
symbol = "XAUUSD"  # Oro frente al dólar
timeframe = mt5.TIMEFRAME_H1  # Velas de 1 hora

print(f"\nAnalizando {symbol}...")

# Obtener datos históricos (últimas 1500 velas)
rates = mt5.copy_rates_from_pos(symbol, timeframe, 0, 1500)

if rates is None or len(rates) == 0:
    print(f"Error: No se pudieron obtener datos para {symbol}")
    mt5.shutdown()
    exit(1)

# Convertir a DataFrame para mejor manejo
rates_df = pd.DataFrame(rates)
rates_df['time'] = pd.to_datetime(rates_df['time'], unit='s')

# Extraer datos
close_prices = rates_df['close'].values  # Precios de cierre
high_prices = rates_df['high'].values    # Precios máximos
low_prices = rates_df['low'].values      # Precios mínimos
open_prices = rates_df['open'].values    # Precios de apertura
volume = rates_df['tick_volume'].values  # Volumen
times = rates_df['time'].values          # Tiempos

print(f"✅ Datos obtenidos: {len(close_prices)} velas para {symbol}")
print(f"📊 Rango de precios: ${min(close_prices):.2f} - ${max(close_prices):.2f}")
print(f"📅 Período: {times[0]} a {times[-1]}")

# Función para crear secuencias para LSTM
def crear_secuencias(datos, longitud_secuencia=60):
    """Crea secuencias para predicción de series temporales"""
    X, y = [], []
    for i in range(longitud_secuencia, len(datos)):
        X.append(datos[i-longitud_secuencia:i])
        y.append(datos[i])
    return np.array(X), np.array(y)

# Normalizar los datos
scaler = MinMaxScaler(feature_range=(0, 1))
datos_escalados = scaler.fit_transform(close_prices.reshape(-1, 1))

# Crear secuencias
longitud_secuencia = 60  # Usamos 60 velas (2.5 días en H1)
X, y = crear_secuencias(datos_escalados, longitud_secuencia)

# Dividir datos en entrenamiento y prueba
ratio_entrenamiento = 0.8
split_idx = int(len(X) * ratio_entrenamiento)

X_entrenamiento, X_prueba = X[:split_idx], X[split_idx:]
y_entrenamiento, y_prueba = y[:split_idx], y[split_idx:]

print(f"\n📈 Datos de entrenamiento: {X_entrenamiento.shape[0]} muestras")
print(f"📉 Datos de prueba: {X_prueba.shape[0]} muestras")

# --- CONSTRUIR MODELO LSTM MEJORADO ---
modelo = tf.keras.Sequential([
    # Primera capa LSTM con return sequences para apilar
    tf.keras.layers.LSTM(100, return_sequences=True, 
                         input_shape=(longitud_secuencia, 1)),
    tf.keras.layers.Dropout(0.3),
    
    # Segunda capa LSTM
    tf.keras.layers.LSTM(80, return_sequences=True),
    tf.keras.layers.Dropout(0.3),
    
    # Tercera capa LSTM
    tf.keras.layers.LSTM(50, return_sequences=False),
    tf.keras.layers.Dropout(0.2),
    
    # Capas densas
    tf.keras.layers.Dense(25, activation='relu'),
    tf.keras.layers.Dense(10, activation='relu'),
    tf.keras.layers.Dense(1)
])

# Compilar el modelo
modelo.compile(
    optimizer=tf.keras.optimizers.Adam(learning_rate=0.001),
    loss='mean_squared_error',
    metrics=['mae', 'mse']
)

# Resumen del modelo
print("\n🧠 ESTRUCTURA DEL MODELO:")
modelo.summary()

# Callbacks para mejorar el entrenamiento
callbacks = [
    tf.keras.callbacks.EarlyStopping(
        monitor='val_loss',
        patience=10,
        restore_best_weights=True,
        verbose=1
    ),
    tf.keras.callbacks.ReduceLROnPlateau(
        monitor='val_loss',
        factor=0.5,
        patience=5,
        min_lr=0.00001,
        verbose=1
    )
]

# Entrenar el modelo
print("\n🚀 Iniciando entrenamiento del modelo...")
historial = modelo.fit(
    X_entrenamiento, y_entrenamiento,
    epochs=80,
    batch_size=32,
    validation_data=(X_prueba, y_prueba),
    callbacks=callbacks,
    verbose=1
)

# Hacer predicciones
print("\n🎯 Generando predicciones...")
predicciones_entrenamiento = modelo.predict(X_entrenamiento)
predicciones_prueba = modelo.predict(X_prueba)

# Revertir la normalización
predicciones_entrenamiento = scaler.inverse_transform(predicciones_entrenamiento)
predicciones_prueba = scaler.inverse_transform(predicciones_prueba)
y_entrenamiento_real = scaler.inverse_transform(y_entrenamiento)
y_prueba_real = scaler.inverse_transform(y_prueba)

# Calcular métricas de error
rmse_entrenamiento = np.sqrt(np.mean((predicciones_entrenamiento - y_entrenamiento_real) ** 2))
rmse_prueba = np.sqrt(np.mean((predicciones_prueba - y_prueba_real) ** 2))
mae_prueba = np.mean(np.abs(predicciones_prueba - y_prueba_real))
mape_prueba = np.mean(np.abs((predicciones_prueba - y_prueba_real) / y_prueba_real)) * 100

print("\n📊 MÉTRICAS DE RENDIMIENTO:")
print(f"✅ RMSE Entrenamiento: ${rmse_entrenamiento:.2f}")
print(f"✅ RMSE Prueba: ${rmse_prueba:.2f}")
print(f"✅ MAE Prueba: ${mae_prueba:.2f}")
print(f"✅ MAPE Prueba: {mape_prueba:.2f}%")

# Predecir el próximo precio
datos_ultimos = datos_escalados[-longitud_secuencia:].reshape(1, longitud_secuencia, 1)
precio_siguiente_escalado = modelo.predict(datos_ultimos)
precio_siguiente = scaler.inverse_transform(precio_siguiente_escalado)

print(f"\n💰 PREDICCIÓN PARA EL ORO:")
print(f"📌 Precio actual: ${close_prices[-1]:.2f}")
print(f"🔮 Precio predicho (próxima vela): ${precio_siguiente[0][0]:.2f}")
print(f"📈 Cambio esperado: ${(precio_siguiente[0][0] - close_prices[-1]):.2f}")

# Calcular soporte y resistencia estimados
soporte = min(close_prices[-50:])
resistencia = max(close_prices[-50:])
print(f"⬇️ Soporte (50 velas): ${soporte:.2f}")
print(f"⬆️ Resistencia (50 velas): ${resistencia:.2f}")

# --- VISUALIZACIÓN DE RESULTADOS ---
plt.figure(figsize=(16, 10))

# Gráfico 1: Predicciones vs Real
plt.subplot(3, 1, 1)
# Datos de entrenamiento
plt.plot(times[longitud_secuencia:longitud_secuencia + len(predicciones_entrenamiento)], 
         y_entrenamiento_real, label='Real (Entrenamiento)', color='blue', alpha=0.6, linewidth=0.8)
plt.plot(times[longitud_secuencia:longitud_secuencia + len(predicciones_entrenamiento)], 
         predicciones_entrenamiento, label='Predicción (Entrenamiento)', color='red', alpha=0.6, linewidth=0.8)
# Datos de prueba
plt.plot(times[longitud_secuencia + len(predicciones_entrenamiento):], 
         y_prueba_real, label='Real (Prueba)', color='green', alpha=0.7, linewidth=1.2)
plt.plot(times[longitud_secuencia + len(predicciones_entrenamiento):], 
         predicciones_prueba, label='Predicción (Prueba)', color='orange', alpha=0.7, linewidth=1.2)
plt.title(f'Predicción de Precio del ORO ({symbol}) - Modelo LSTM', fontsize=14, fontweight='bold')
plt.xlabel('Tiempo')
plt.ylabel('Precio (USD)')
plt.legend(loc='upper left')
plt.grid(True, alpha=0.3)

# Gráfico 2: Pérdida del modelo
plt.subplot(3, 1, 2)
plt.plot(historial.history['loss'], label='Pérdida Entrenamiento', linewidth=1.5)
plt.plot(historial.history['val_loss'], label='Pérdida Validación', linewidth=1.5)
plt.title('Evolución de la Pérdida del Modelo', fontsize=14, fontweight='bold')
plt.xlabel('Época')
plt.ylabel('Pérdida (MSE)')
plt.legend()
plt.grid(True, alpha=0.3)

# Gráfico 3: MAE del modelo
plt.subplot(3, 1, 3)
plt.plot(historial.history['mae'], label='MAE Entrenamiento', linewidth=1.5)
plt.plot(historial.history['val_mae'], label='MAE Validación', linewidth=1.5)
plt.title('Error Absoluto Medio (MAE)', fontsize=14, fontweight='bold')
plt.xlabel('Época')
plt.ylabel('MAE (USD)')
plt.legend()
plt.grid(True, alpha=0.3)

plt.tight_layout()
plt.show()

# --- ANÁLISIS ADICIONAL ---
print("\n📋 ANÁLISIS DE PRECIOS RECIENTES:")
print("-" * 60)
# Mostrar últimas 10 velas
print("Últimas 10 velas (Hora | Apertura | Máximo | Mínimo | Cierre):")
ultimas_10 = rates_df.tail(10)[['time', 'open', 'high', 'low', 'close']]
for idx, row in ultimas_10.iterrows():
    print(f"  {row['time'].strftime('%Y-%m-%d %H:%M')} | ${row['open']:.2f} | ${row['high']:.2f} | ${row['low']:.2f} | ${row['close']:.2f}")

# Predecir próximas 5 velas
print("\n🔮 PREDICCIÓN DE PRÓXIMAS 5 VELAS:")
precios_futuros = []
datos_actuales = datos_escalados[-longitud_secuencia:].reshape(1, longitud_secuencia, 1)

for i in range(5):
    pred = modelo.predict(datos_actuales, verbose=0)
    precios_futuros.append(scaler.inverse_transform(pred)[0][0])
    # Actualizar datos para la siguiente predicción
    datos_actuales = np.roll(datos_actuales, -1, axis=1)
    datos_actuales[0, -1, 0] = pred[0, 0]

for i, precio in enumerate(precios_futuros, 1):
    cambio = precio - close_prices[-1]
    cambio_pct = (cambio / close_prices[-1]) * 100
    flecha = "📈" if cambio > 0 else "📉" if cambio < 0 else "➡️"
    print(f"  Vela {i}: ${precio:.2f} ({flecha} {cambio:+.2f} | {cambio_pct:+.2f}%)")

# Guardar el modelo si es bueno
if rmse_prueba < 20:  # Si el error es menor a $20
    modelo.save(f'modelo_oro_{datetime.now().strftime("%Y%m%d")}.h5')
    print(f"\n💾 Modelo guardado como 'modelo_oro_{datetime.now().strftime('%Y%m%d')}.h5'")

# Cerrar conexión con MT5
mt5.shutdown()
print("\n🔄 MT5 cerrado correctamente")