# Barberia Control Demo

Demo para registrar cortes, pagos en efectivo, pagos por Nequi con comprobante, cierre de caja y agenda conectada con WhatsApp.

## Ejecutar

Modo recomendado para barberos con datos moviles:

```text
Doble clic en Iniciar Barberia Internet.cmd
```

Ese arrancador revisa Python y Node, intenta descargarlos si faltan, compila Angular si hace falta, valida el servidor, deja Admin disponible en la laptop y crea el acceso publico por ngrok.
Los barberos pueden guardar este link fijo:

```text
https://kimono-punch-diving.ngrok-free.dev/barberos
```

Ese link solo funciona mientras la ventana del servidor este abierta. Si el servidor esta apagado, los barberos no cambian de link: cuando vuelvas a abrir `Iniciar Barberia Internet.cmd`, solo refrescan la pagina.
El arrancador tambien copia el link y lo guarda en `LINK_BARBEROS.txt`.
Para apagar todo, cierra la ventana del arrancador o usa `Ctrl+C`; el servidor local y el tunel de internet se cierran junto con esa ventana.

No compartas links `http://192.168...` o de red Wi-Fi local si los barberos van a entrar con datos moviles. Comparte el link HTTPS que queda en `LINK_BARBEROS.txt`.

Modo local solo para administracion o pruebas en la laptop:

```text
Doble clic en Iniciar Barberia.cmd
```

Ese modo abre el servidor sin tunel publico. Sirve para administrar desde la laptop, pero no es el modo correcto para compartir con barberos fuera de la red.

### Link fijo con ngrok

La configuracion de ngrok vive en:

```text
tools\ngrok\authtoken.txt
tools\ngrok\public-url.txt
```

El dominio configurado actualmente es:

```text
https://kimono-punch-diving.ngrok-free.dev
```

No compartas `authtoken.txt`; ese archivo permite usar tu cuenta de ngrok.

Si algun dia cambias el dominio en ngrok, actualiza `tools\ngrok\public-url.txt` y vuelve a abrir el arrancador.

Opcion manual:

```powershell
python server.py
```

## Links

Admin en la laptop:

```text
http://localhost:8000/admin
```

Barberos:

```text
https://kimono-punch-diving.ngrok-free.dev/barberos
```

El link vigente para barberos queda en `LINK_BARBEROS.txt`. Debe ser un link `https://.../barberos`, no una IP local.

Si Windows pregunta por permisos de red, permitir Python en la red privada para que el tunel pueda llegar al servidor local.

## Datos

- Las ventas y citas se guardan en `data/db.json`.
- Las capturas de Nequi se guardan en `data/uploads`.
- El frontend Angular vive en `frontend/`.
- El build que sirve Python queda en `frontend/dist/frontend/browser`.
- La carpeta vieja `public/` fue eliminada; la app se sirve solo desde Angular.
- Los pagos en efectivo quedan confirmados automaticamente.
- Los pagos por Nequi quedan pendientes hasta que administracion los confirme o rechace.
- La app usa eventos en tiempo real: cuando un barbero registra algo, Admin y otros celulares se actualizan solos.
- Admin puede ver el historial de comprobantes Nequi y abrir las fotos aunque el pago ya este confirmado o rechazado.
- El cierre del dia se hace desde Admin con el boton `Cerrar dia`.
- Al cerrar el dia se guarda un historial en `data/db.json` y los barberos no pueden registrar mas ventas.
- Si se necesita corregir algo, Admin puede usar `Reabrir dia`.
- Si entran por `/barberos`, la pestana Admin queda oculta y solo ven Barberos y Agenda.
- Cuando se usa el tunel de internet, `/admin` se redirige a `/barberos` y las acciones administrativas quedan disponibles solo desde la laptop o red local, no desde el link publico.
