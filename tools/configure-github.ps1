param(
  [string]$AppRoot = ""
)

$ErrorActionPreference = "Stop"
$OutputEncoding = [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

if (-not $AppRoot) {
  $AppRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
} else {
  $AppRoot = (Resolve-Path $AppRoot).Path
}

$RepositoryUrl = "https://github.com/Camilo236yt/Barberia.git"
$PortableGit = Join-Path $env:LOCALAPPDATA "CapitanGold\Git\cmd\git.exe"
$GitExe = if (Test-Path -LiteralPath $PortableGit) {
  $PortableGit
} else {
  (Get-Command git.exe -ErrorAction SilentlyContinue).Source
}
if (-not $GitExe) {
  $GitExe = (Get-Command git -ErrorAction SilentlyContinue).Source
}
if (-not $GitExe) {
  Write-Host "No se encontro Git. Ejecuta primero Instalar Barberia.cmd." -ForegroundColor Red
  exit 1
}

function Invoke-Git($Arguments, [switch]$AllowFailure) {
  $previousPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = "Continue"
    $lines = @(& $GitExe -C $AppRoot @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousPreference
  }
  $text = (($lines | ForEach-Object { "$_" }) -join [Environment]::NewLine).Trim()
  if ($exitCode -ne 0 -and -not $AllowFailure) {
    throw $(if ($text) { $text } else { "Git termino con el codigo $exitCode." })
  }
  return [pscustomobject]@{ ExitCode = $exitCode; Text = $text }
}

try {
  Write-Host ""
  Write-Host "Configurando los respaldos de Capitan Gold..." -ForegroundColor Cyan

  if (-not (Test-Path -LiteralPath (Join-Path $AppRoot ".git"))) {
    Write-Host "Reconstruyendo la conexion Git de esta instalacion..."
    Invoke-Git @("init", "--quiet") | Out-Null
  }

  $origin = Invoke-Git @("remote", "get-url", "origin") -AllowFailure
  if ($origin.ExitCode -ne 0) {
    Invoke-Git @("remote", "add", "origin", $RepositoryUrl) | Out-Null
  } elseif ($origin.Text -ne $RepositoryUrl) {
    Invoke-Git @("remote", "set-url", "origin", $RepositoryUrl) | Out-Null
  }

  Remove-Item Env:\GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue
  $env:GCM_INTERACTIVE = "Always"

  # Git Credential Manager guarda la sesion cifrada para el usuario de Windows.
  Invoke-Git @("credential-manager", "configure") -AllowFailure | Out-Null

  Write-Host ""
  Write-Host "Se abrira el inicio de sesion de GitHub si este PC aun no esta autorizado." `
    -ForegroundColor Yellow
  Write-Host "Usa una cuenta con permiso de escritura en Camilo236yt/Barberia."
  Write-Host ""

  $connection = Invoke-Git @("ls-remote", "--exit-code", "origin", "HEAD") -AllowFailure
  if ($connection.ExitCode -ne 0) {
    throw $connection.Text
  }

  $fetch = Invoke-Git @("fetch", "--quiet", "--no-tags", "origin", "main") -AllowFailure
  if ($fetch.ExitCode -ne 0) {
    throw $fetch.Text
  }
  $writeCheck = Invoke-Git @(
    "push", "--dry-run", "--quiet", "origin", "FETCH_HEAD:refs/heads/main"
  ) -AllowFailure
  if ($writeCheck.ExitCode -ne 0) {
    throw $writeCheck.Text
  }
  Write-Host ""
  Write-Host "Este PC ya puede leer y guardar respaldos en GitHub." -ForegroundColor Green
  Write-Host "La autorizacion quedo guardada para los respaldos automaticos."
  exit 0
} catch {
  $message = $_.Exception.Message
  if (
    $message -match "Authentication failed|could not read Username|interactiv.*disabled|" +
      "permission denied|write access.*not granted|HTTP 403|returned error: 403|" +
      "repository not found"
  ) {
    $message = (
      "GitHub no autorizo este PC. Inicia sesion con una cuenta que tenga permiso " +
      "de escritura en el repositorio Camilo236yt/Barberia."
    )
  }
  Write-Host ""
  Write-Host $message -ForegroundColor Red
  exit 1
}
