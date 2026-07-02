param(
  [string]$RepositoryUrl = "https://github.com/Camilo236yt/Barberia.git",
  [string]$InstallPath = "",
  [switch]$NoLaunch,
  [switch]$NoShortcuts
)

$ErrorActionPreference = "Stop"
if (-not $InstallPath) {
  $InstallPath = Join-Path $env:LOCALAPPDATA "CapitanGold\Barberia"
}

function Write-Install($Message) {
  Write-Host "[Instalador] $Message"
}

try {
  $git = Get-Command git.exe -ErrorAction SilentlyContinue
  if (-not $git) { $git = Get-Command git -ErrorAction SilentlyContinue }
  if (-not $git) {
    throw "Git no esta instalado. Instalalo y vuelve a ejecutar este instalador."
  }
  $python = Get-Command python.exe -ErrorAction SilentlyContinue
  if (-not $python) { $python = Get-Command python -ErrorAction SilentlyContinue }
  if (-not $python) {
    throw "Python 3 no esta instalado."
  }

  if (Test-Path -LiteralPath $InstallPath) {
    if (-not (Test-Path -LiteralPath (Join-Path $InstallPath ".git"))) {
      throw "La carpeta de destino ya existe y no es una instalacion valida: $InstallPath"
    }
    Write-Install "La aplicacion ya esta instalada. Buscando actualizaciones..."
    & $git.Source -C $InstallPath pull --ff-only origin main
    if ($LASTEXITCODE -ne 0) { throw "No se pudo actualizar la instalacion existente." }
  } else {
    $parent = Split-Path -Parent $InstallPath
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    Write-Install "Descargando solamente el programa, sin historiales anteriores..."
    & $git.Source clone `
      --filter=blob:none `
      --depth 1 `
      --single-branch `
      --branch main `
      --no-checkout `
      $RepositoryUrl `
      $InstallPath
    if ($LASTEXITCODE -ne 0) { throw "Git no pudo descargar el programa." }

    & $git.Source -C $InstallPath sparse-checkout init --no-cone
    & $git.Source -C $InstallPath sparse-checkout set --no-cone `
      "/*" `
      "!/data/" `
      "!/tools/node/" `
      "!/tools/cloudflared/" `
      "!/tools/cloudflare-worker/" `
      "!/tools/backups/" `
      "!/tools/logs/" `
      "!/frontend/node_modules/"
    if ($LASTEXITCODE -ne 0) { throw "No se pudo preparar la instalacion liviana." }
    & $git.Source -C $InstallPath checkout main
    if ($LASTEXITCODE -ne 0) { throw "No se pudo finalizar la descarga." }
  }

  if (-not $NoShortcuts) {
    $desktop = [Environment]::GetFolderPath("Desktop")
    $shell = New-Object -ComObject WScript.Shell
    foreach ($shortcutInfo in @(
      @{ Name = "Capitan Gold.lnk"; Target = "Iniciar Barberia.cmd" },
      @{ Name = "Capitan Gold Internet.lnk"; Target = "Iniciar Barberia Internet.cmd" }
    )) {
      $shortcut = $shell.CreateShortcut((Join-Path $desktop $shortcutInfo.Name))
      $shortcut.TargetPath = Join-Path $InstallPath $shortcutInfo.Target
      $shortcut.WorkingDirectory = $InstallPath
      $shortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,220"
      $shortcut.Save()
    }
  }

  Write-Host ""
  Write-Install "Instalacion completada en: $InstallPath"
  Write-Install "Los meses anteriores no fueron descargados."
  Write-Install "Puedes recuperarlos desde Historial > Buscar respaldos."
  if (-not $NoLaunch) {
    Start-Process -FilePath (Join-Path $InstallPath "Iniciar Barberia.cmd") `
      -WorkingDirectory $InstallPath
  }
  exit 0
} catch {
  Write-Host ""
  Write-Host "No se pudo instalar Capitan Gold:" -ForegroundColor Red
  Write-Host $_.Exception.Message -ForegroundColor Red
  exit 1
}
