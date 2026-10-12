# Gold Master / MetaQuotes: repositorio de fuentes

Raíz: MetaQuotes; no incluye las otras aplicaciones de AppData/Roaming.

## Alcance
Fuentes de MQL5, EAs, indicadores, scripts, servicios y terminal replay web bajo Terminal/D0E8209F77C8CF37AD8BF550E51FF075/MQL5. MT5 y MetaEditor se instalan aparte; no se distribuye ni se puede reconstruir su núcleo propietario con este repositorio.

## Trabajo con Claude
Clonar el repositorio en una carpeta independiente, abrirlo en Claude y trabajar mediante ramas. Revisar los diffs y compilar antes de copiar fuentes o compilados al terminal local. No ejecutar órdenes reales ni subir credenciales. No modificar simultáneamente el mismo archivo desde dos agentes; coordinar cambios y responsables en CODEX.md local. El repositorio remoto y el primer commit quedan pendientes de URL y autor Git.

## Entorno
Python: instalar dependencias desde requirements.txt del servicio elegido en un entorno virtual nuevo; no copiar el entorno virtual local. Web replay: desde replay_terminal ejecutar python -m web --port 8766 --no-browser. MQL5: abrir fuentes en MetaEditor y compilar localmente. Los datos históricos y cuentas no se incluyen; cargar datos desde el terminal propio.

## Datos excluidos
Cuentas, configuraciones del terminal, contraseñas, registros, SQLite, CSV de mercado, cachés, binarios compilados, entornos virtuales y archivos temporales permanecen fuera del control de versiones. No usar git add -f para incluirlos. El repositorio debe ser privado.

## Limitaciones de validación
Las modificaciones de replay de octubre incluyen varios controles revisados solo por sintaxis. Hace falta comprobación visual y pruebas funcionales antes de considerarlo estable. No hay garantía de rentabilidad ni estrategias certificadas por estos cambios.
