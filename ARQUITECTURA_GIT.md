# Acceso del proyecto y credenciales

## Código compartido
El repositorio contiene fuentes editables; MT5, cuentas, datos históricos y compilados se mantienen fuera. El terminal activo guarda sus credenciales localmente. El conector replay utiliza la sesión abierta de MT5: no necesita copiar la contraseña al repositorio.

## Secretos locales
Nunca colocar contraseñas, tokens o certificados en Python, JavaScript, MQL5 ni archivos de configuración versionados. Usar el almacén de credenciales del terminal o variables de entorno cuando el componente soporte esas variables. GM_TERMINAL_PATH es una ruta, no una contraseña; el conector ya la admite. No se han añadido variables ficticias para contraseñas que los motores no leen.

Los directorios .private/secrets, archivos .env, cuentas, INI, logs, SQLite, CSV y cachés están excluidos. git_security_scan.local.json guarda solamente rutas/líneas de hallazgos, nunca valores; permanece local. Esta revisión de patrones no garantiza detectar todos los secretos posibles.

## Copilot Space METATRADER
La captura proporcionada muestra un Space privado con cero fuentes. Después de crear/subir el repositorio privado, agregarlo mediante Add sources y conceder acceso a la cuenta/agente correspondiente. Crear un Space no crea automáticamente un repositorio ni sube la carpeta local. Para editar y entregar cambios, trabajar sobre un clon Git mediante ramas y commits; revisar y aplicar cambios al terminal después.

## Claude
Clonar el repositorio y abrir la carpeta del clon en Claude Code, o conectar el repositorio al entorno de Claude que soporte esa integración. No proporcionar credenciales del broker. Mantener una rama por trabajo y revisar diferencias antes de integrar. Copilot Space es una superficie de GitHub Copilot; la captura no demuestra conexión con Claude.

## Publicación pendiente
Se necesita la URL del repositorio destino y un autor Git para el primer commit. No se ha publicado ningún archivo ni enviado credenciales a servicios externos.
