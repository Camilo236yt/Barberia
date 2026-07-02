# Barbería Control

Sistema de facturación y contabilidad para dos barberías con dos accesos administrativos coordinados.

La interfaz usa la identidad de Capitan Gold Barber Shop y está adaptada para teléfonos Android:

- Navegación inferior de cinco accesos.
- Botones táctiles para elegir barbero y servicio, sin listas desplegables.
- Tablas convertidas en tarjetas en pantallas pequeñas.
- Cuadrículas, calendario y formularios reorganizados para evitar contenido apretado.
- Compatibilidad con áreas seguras y acceso tipo aplicación web.
- Interfaz clásica en blanco y negro con detalles dorados sobrios, manteniendo colores suaves para los estados de contabilidad.

## Iniciar con administrador online

Haz doble clic en:

```text
Iniciar Barberia Internet.cmd
```

El programa:

1. Inicia el servidor y abre `http://localhost:8000/admin`.
2. Muestra un selector para que el administrador de la computadora principal elija su barbería.
3. Crea un nuevo enlace privado para el segundo administrador.
4. Copia el enlace online y lo guarda en `LINK_ADMIN_ONLINE.txt`.
5. Cuando el segundo administrador entra, solo puede elegir la barbería que no está usando el administrador local.

Si una ventana anterior dejó ngrok abierto, el iniciador reutiliza o recupera esa sesión para evitar `ERR_NGROK_334`. No activa `--pooling-enabled`, porque balancear el mismo dominio entre dos computadoras podría mezclar sus datos.

El antiguo enlace de barberos y la agenda de citas continúan eliminados.

## Iniciar sin acceso online

Para trabajar únicamente desde la computadora principal:

```text
Iniciar Barberia.cmd
```

Acceso local:

```text
http://localhost:8000/admin
```

## Separación de las barberías

- Cada administrador selecciona una sede.
- La sede elegida por uno desaparece de las opciones del otro.
- El servidor rechaza cualquier intento de leer, facturar o cerrar la caja de la otra sede.
- Ventas, caja, Nequi, comisiones e historial permanecen separados.
- La pestaña `Información` permite crear, editar y eliminar los barberos, servicios y precios de cada sede.
- Los cambios de información de una barbería no afectan a la otra.
- Las ventas históricas conservan el nombre del barbero, servicio y precio originales.
- En `Facturar corte`, la opción `Servicio especial` permite escribir un nombre y precio libre para ofertas, descuentos o cobros especiales sin modificar el catálogo normal.
- En `Contabilidad`, el calendario separa los movimientos por día: verde indica que hubo facturación, rojo que no hubo ventas y gris que la fecha todavía no ha llegado.
- Al seleccionar un día se filtran sus totales, pagos Nequi, movimientos y comisiones.
- Las asignaciones se reinician al reiniciar el servidor.

## Sedes, equipo y precios iniciales

Barbería de Arriba:

- Jose
- Luís
- Samuel

Barbería de Abajo:

- Omar
- Randy
- Juan

Servicios en ambas sedes:

- Corte con tijeras: $25.000
- Corte básico: $23.000
- Barba: $15.000
- Corte y barba: $35.000
- Corte con tijeras y barba: $40.000

## Actualizaciones automáticas

Los dos iniciadores consultan la rama `main` del repositorio Git antes de abrir el sistema:

- Si no hay cambios, el programa inicia normalmente.
- Si no hay internet, la comprobación se omite y el programa continúa.
- Si existe una versión nueva, aparece un aviso con sus cambios y botones para actualizar ahora o posponerla.
- Antes de actualizar se respaldan la contabilidad, los comprobantes, los tokens y la configuración local.
- Después de instalar una versión se usa el panel precompilado y se valida el servidor; las herramientas de desarrollo no se descargan al cliente.
- Si hay archivos modificados, faltantes o incompatibles, se copian en `%LOCALAPPDATA%\CapitanGold\updates\recovery`, se fuerza la versión oficial y se eliminan los sobrantes.
- Una actualización interrumpida recupera automáticamente los datos locales en el siguiente inicio.

Antes de publicar por primera vez esta función, deja de seguir los datos locales que ya existían en el historial:

```text
git rm -r --cached data __pycache__ tools/logs tools/backups
git rm --cached LINK_ADMIN_ONLINE.txt tools/ngrok/public-url.txt tools/cloudflare-worker/public-url.txt
git rm -r --cached tools/node tools/cloudflared
```

Este paso no borra los archivos de la computadora; solamente evita que Git vuelva a publicarlos. Después, los comentarios mostrados al cliente salen del título y la descripción de cada commit. Para publicar una actualización con información clara:

```text
npm --prefix frontend run build
git add .
git add -f frontend/dist
git commit -m "Título breve de la actualización" -m "Explicación de las mejoras y correcciones para el cliente."
git push origin main
```

Git debe estar instalado y la copia del cliente debe conservar su carpeta `.git`. Los datos privados y archivos generados están excluidos mediante `.gitignore`.

## Instalador liviano

Entrega al cliente `Instalar Barberia.cmd` junto con `Instalar Barberia.ps1`. El instalador:

- Clona únicamente la versión más reciente de `main`.
- Omite Node, Cloudflared, dependencias de desarrollo, registros y datos.
- No descarga la rama `historial-datos` ni los meses anteriores.
- Instala el programa en `%LOCALAPPDATA%\CapitanGold\Barberia`.
- Instala Python portátil y ngrok desde sus fuentes oficiales.
- Conserva esas dependencias durante las actualizaciones y recupera Python automáticamente si falta.
- Usa Git instalado o instala Git for Windows oficial con acceso seguro a GitHub cuando no está disponible.
- No crea accesos directos y elimina los antiguos creados por versiones anteriores.
- Al finalizar inicia el servidor y abre el panel en el navegador predeterminado.

El panel compilado se publica en `frontend/dist`, por lo que la computadora del cliente no necesita Node ni las dependencias Angular de desarrollo. La instalación completa probada ocupa aproximadamente 55 MB.

## Respaldos mensuales en GitHub

Al cerrar o reabrir una caja, el servidor crea `data/history-archives/AAAA-MM-DD.zip` con las ventas, cierres, configuración y comprobantes del día. Después lo sube automáticamente a la rama independiente `historial-datos`, sin cambiar `main`. Una barra muestra si está preparando, subiendo, completado o si GitHub devolvió un error. Los días se agrupan por mes en la interfaz y se descargan juntos para evitar archivos demasiado grandes.

En `Historial > Buscar respaldos` aparecen los meses disponibles. Un mes remoto solo se descarga cuando el administrador pulsa `Descargar`; entonces sus cierres aparecen en el calendario y sus comprobantes vuelven a estar disponibles.

El repositorio debe ser privado y la cuenta configurada en Git debe tener permiso de escritura. Si no hay conexión o autenticación, el ZIP permanece local y la pantalla muestra el estado del respaldo.

## Seguridad

El enlace online contiene un token privado generado por el sistema. No debe compartirse con clientes ni barberos.

- El token se guarda en `data/admin-online-token.txt`.
- El enlace vigente se guarda en `LINK_ADMIN_ONLINE.txt`.
- La información se conserva en `data/db.json`.
- Los comprobantes se guardan en `data/uploads`.

Para apagar el sistema, cierra la ventana del arrancador o usa `Ctrl+C`.

También puedes cerrar la pestaña administrativa local del navegador. El sistema espera unos segundos para distinguir una recarga normal y después apaga automáticamente el servidor, el enlace online y la ventana del iniciador. Cerrar únicamente la pestaña del administrador online no apaga la computadora principal.
