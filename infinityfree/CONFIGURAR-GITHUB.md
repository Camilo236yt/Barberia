# Conectar InfinityFree con GitHub

InfinityFree no ejecuta Git directamente. Capitán Gold usa dos conexiones
seguras:

- PHP → API de GitHub para subir y recuperar respaldos.
- GitHub Actions → FTP de InfinityFree para publicar actualizaciones.

## 1. Token para los respaldos

En GitHub abre **Settings → Developer settings → Personal access tokens →
Fine-grained tokens** y crea un token con:

- Acceso únicamente a `Camilo236yt/Barberia`.
- Permiso del repositorio **Contents: Read and write**.

No publiques ni envíes este token por chat. Agrégalo en
`htdocs/api/config.php`:

```php
'GITHUB_REPOSITORY' => 'Camilo236yt/Barberia',
'GITHUB_HISTORY_BRANCH' => 'historial-datos',
'GITHUB_TOKEN' => 'AQUI_VA_EL_TOKEN_FINE_GRAINED',
```

Después vuelve a subir `config.php`. El botón **Subir datos de hoy** guardará el
estado completo, el día seleccionado y sus comprobantes en la rama
`historial-datos`. **Buscar respaldo** descargará los meses disponibles y
combinará los registros por identificador, sin duplicarlos.

## 2. Actualizaciones automáticas

En el repositorio abre **Settings → Secrets and variables → Actions** y crea
estos secretos con los datos FTP que muestra InfinityFree:

- `INFINITYFREE_FTP_SERVER`
- `INFINITYFREE_FTP_USERNAME`
- `INFINITYFREE_FTP_PASSWORD`

En la pestaña **Variables** crea:

```text
INFINITYFREE_DEPLOY_ENABLED = true
```

Luego abre **Actions → Actualizar InfinityFree → Run workflow**. Desde ese
momento, cada actualización relevante subida a `main` se compilará y llegará a
InfinityFree por FTP.

El despliegue excluye expresamente:

- `api/config.php`
- `api/migration-data*.json`
- `uploads/`
- `importar.html`

Por eso una actualización no reemplaza las credenciales, la migración pendiente
ni los comprobantes. Los registros permanecen en MySQL.
