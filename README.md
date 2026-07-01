# Barbería Control

Sistema de facturación y contabilidad para dos barberías con dos accesos administrativos coordinados.

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

## Seguridad

El enlace online contiene un token privado generado por el sistema. No debe compartirse con clientes ni barberos.

- El token se guarda en `data/admin-online-token.txt`.
- El enlace vigente se guarda en `LINK_ADMIN_ONLINE.txt`.
- La información se conserva en `data/db.json`.
- Los comprobantes se guardan en `data/uploads`.

Para apagar el sistema, cierra la ventana del arrancador o usa `Ctrl+C`.
