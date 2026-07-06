# Capitan Gold en InfinityFree

Este paquete conserva la interfaz Angular del programa de escritorio. En
InfinityFree el servidor se ejecuta con PHP 8 y guarda el estado completo en
MySQL porque el alojamiento gratuito no permite ejecutar `server.py`.

## 1. Crear la base de datos

1. En el panel de InfinityFree abre **MySQL Databases**.
2. Crea una base y guarda estos cuatro datos: host, nombre, usuario y contraseña.
3. Abre phpMyAdmin, selecciona la base e importa `schema.sql`.

## 2. Configurar

1. Copia `htdocs/api/config.example.php` como `htdocs/api/config.php`.
2. Completa las credenciales MySQL.
3. Cambia `ADMIN_TOKEN` e `IMPORT_SECRET` por dos valores largos y diferentes.
4. No compartas `config.php` ni lo subas a GitHub.

El enlace administrativo será:

`https://TU-DOMINIO/admin/online?token=TU_ADMIN_TOKEN`

## 3. Subir los archivos

Sube **el contenido** de `htdocs` a la carpeta `htdocs` de InfinityFree mediante
FTP. No subas la carpeta exterior `infinityfree`.

Todos los archivos individuales cumplen el límite de 10 MB. La interfaz ya está
compilada; no se suben Node, Python, ngrok ni `node_modules`.

## 4. Importar los datos existentes

El exportador genera `htdocs/api/migration-data.json` y copia los comprobantes a
`htdocs/uploads`. Después de subirlos:

1. Abre el enlace administrativo.
2. Desde una terminal o Postman envía:

```text
POST https://TU-DOMINIO/api/import
X-Import-Secret: TU_IMPORT_SECRET
Content-Type: application/json

{}
```

La importación combina por identificador, por lo que no duplica ventas, gastos
ni cierres. Al terminar, `migration-data.json` se elimina del servidor para que
la información temporal no quede expuesta ni vuelva a importarse.

## 5. Verificación antes de trabajar

- Comprueba ambas barberías.
- Compara el número de ventas y el total de un día conocido.
- Revisa un comprobante Nequi.
- Registra una venta de prueba y elimínala.
- Conserva el ZIP de respaldo creado antes de la migración.

El botón de respaldo del sitio cloud confirma que MySQL ya tiene los datos. La
copia histórica de GitHub del programa de escritorio se conserva y no se borra.

## 6. GitHub y actualizaciones

Para conectar los botones de respaldo y activar actualizaciones automáticas,
sigue `CONFIGURAR-GITHUB.md`. Las credenciales se guardan como secretos y nunca
se incluyen en el repositorio.
