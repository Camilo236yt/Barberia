# Cloudflare Worker proxy

Este Worker intenta quitar el aviso gratis de ngrok usando un proxy.

Flujo:

```text
Clientes -> Cloudflare Worker -> ngrok fijo -> servidor local
```

El Worker agrega este header cuando llama a ngrok:

```text
ngrok-skip-browser-warning: true
```

## Desplegar

Desde esta carpeta:

```powershell
npx wrangler login
npx wrangler deploy
```

Cuando Cloudflare muestre el link `https://...workers.dev`, guardalo en:

```text
tools\cloudflare-worker\public-url.txt
```

Después abre `Iniciar Barberia Internet.cmd`. El servidor seguirá iniciando ngrok por detrás, pero el enlace público de citas para clientes pasará por el Worker. La facturación administrativa no se publica en internet.
