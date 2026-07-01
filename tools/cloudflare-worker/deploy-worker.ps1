param(
  [switch]$NoLogin
)

$ErrorActionPreference = "Stop"
$WorkerRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$AppRoot = (Resolve-Path (Join-Path $WorkerRoot "..\..")).Path
$PublicUrlPath = Join-Path $WorkerRoot "public-url.txt"

function Find-Npm {
  $portableNpm = Get-ChildItem -Path (Join-Path $AppRoot "tools\node") -Recurse -Filter "npm.cmd" -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if ($portableNpm) {
    return $portableNpm.FullName
  }

  $command = Get-Command npm -ErrorAction SilentlyContinue
  if ($command) {
    return $command.Source
  }

  throw "No se encontro npm. Abre primero Iniciar Barberia Internet.cmd para preparar Node."
}

$npm = Find-Npm
$nodeDir = Split-Path $npm -Parent
$env:Path = "$nodeDir;$env:Path"
$wrangler = Join-Path $WorkerRoot "node_modules\.bin\wrangler.cmd"

Push-Location $WorkerRoot
try {
  if (-not (Test-Path $wrangler)) {
    Write-Host "[Worker] Instalando Wrangler local..."
    & $npm install
    if ($LASTEXITCODE -ne 0) {
      throw "No se pudo instalar Wrangler."
    }
  }

  if (-not $NoLogin) {
    Write-Host "[Worker] Si no has iniciado sesion, se abrira login de Cloudflare."
    & $wrangler login
    if ($LASTEXITCODE -ne 0) {
      throw "No se completo el login de Cloudflare."
    }
  }

  Write-Host "[Worker] Desplegando proxy..."
  $output = & $wrangler deploy 2>&1
  $output | ForEach-Object { Write-Host $_ }
  if ($LASTEXITCODE -ne 0) {
    throw "No se pudo desplegar el Worker."
  }

  $matches = $output | Select-String -Pattern "https://[a-zA-Z0-9.-]+\.workers\.dev" -AllMatches
  $url = $matches.Matches.Value | Select-Object -Last 1
  if ($url) {
    Set-Content -LiteralPath $PublicUrlPath -Value $url -Encoding UTF8
    Write-Host "[Worker] URL guardada en $PublicUrlPath"
  } else {
    Write-Host "[Worker] No pude detectar la URL. Copiala manualmente en $PublicUrlPath"
  }
} finally {
  Pop-Location
}
