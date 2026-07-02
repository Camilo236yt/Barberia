param(
  [string]$RepositoryUrl = "https://github.com/Camilo236yt/Barberia.git",
  [string]$InstallPath = "",
  [switch]$NoLaunch
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if (-not $InstallPath) {
  $InstallPath = Join-Path $env:LOCALAPPDATA "CapitanGold\Barberia"
}
$DependencyRoot = Join-Path $env:LOCALAPPDATA "CapitanGold"
$PythonVersion = "3.13.14"
$PythonSha256 = "90b4e5b9898b72d744650524bff92377c367f44bd5fbd09e3148656c080ad907"

function Write-Install($Message) {
  Write-Host "[Instalador] $Message"
}

function Test-Executable($FilePath, $Arguments) {
  if (-not $FilePath -or -not (Test-Path -LiteralPath $FilePath)) {
    return $false
  }
  try {
    & $FilePath @Arguments | Out-Null
    return $LASTEXITCODE -eq 0
  } catch {
    return $false
  }
}

function Download-File($Uri, $Destination) {
  $parent = Split-Path -Parent $Destination
  New-Item -ItemType Directory -Path $parent -Force | Out-Null
  Invoke-WebRequest -Uri $Uri -OutFile $Destination -UseBasicParsing
  if (-not (Test-Path -LiteralPath $Destination) -or (Get-Item $Destination).Length -eq 0) {
    throw "La descarga termino vacia: $Uri"
  }
}

function Get-Git {
  foreach ($candidate in @(
    (Get-Command git.exe -ErrorAction SilentlyContinue).Source,
    (Get-Command git -ErrorAction SilentlyContinue).Source,
    (Join-Path $env:LOCALAPPDATA "Programs\Git\cmd\git.exe"),
    (Join-Path $env:ProgramFiles "Git\cmd\git.exe")
  )) {
    if (Test-Executable $candidate @("--version")) {
      return $candidate
    }
  }

  Write-Install "Git no esta instalado. Descargando Git for Windows oficial..."
  $release = Invoke-RestMethod `
    -Uri "https://api.github.com/repos/git-for-windows/git/releases/latest" `
    -Headers @{ "User-Agent" = "Capitan-Gold-Installer" } `
    -UseBasicParsing
  $asset = $release.assets |
    Where-Object {
      $_.name -match "^Git-.*-64-bit\.exe$"
    } |
    Select-Object -First 1
  if (-not $asset) {
    throw "No se encontro el instalador oficial de Git for Windows de 64 bits."
  }

  $installerPath = Join-Path $env:TEMP "capitan-gold-git-installer.exe"
  Download-File $asset.browser_download_url $installerPath
  Write-Install "Instalando Git y el acceso seguro a GitHub..."
  $process = Start-Process `
    -FilePath $installerPath `
    -ArgumentList @(
      "/VERYSILENT",
      "/NORESTART",
      "/NOCANCEL",
      "/SP-",
      "/CLOSEAPPLICATIONS",
      "/o:PathOption=Cmd",
      "/o:UseCredentialManager=Enabled"
    ) `
    -Wait `
    -PassThru `
    -WindowStyle Hidden
  Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue
  if ($process.ExitCode -ne 0) {
    throw "Git for Windows no pudo instalarse (codigo $($process.ExitCode))."
  }

  $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
  $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
  $env:Path = "$machinePath;$userPath"
  foreach ($candidate in @(
    (Get-Command git.exe -ErrorAction SilentlyContinue).Source,
    (Join-Path $env:LOCALAPPDATA "Programs\Git\cmd\git.exe"),
    (Join-Path $env:ProgramFiles "Git\cmd\git.exe")
  )) {
    if (Test-Executable $candidate @("--version")) {
      return $candidate
    }
  }
  throw "Git se instalo, pero no pudo iniciarse."
}

function Install-PortablePython {
  $pythonDirectory = Join-Path $InstallPath "tools\python"
  $pythonExe = Join-Path $pythonDirectory "python.exe"
  if (Test-Executable $pythonExe @("-c", "import sys; print(sys.version)")) {
    Write-Install "Python portatil ya esta instalado."
    return $pythonExe
  }

  Write-Install "Descargando Python $PythonVersion oficial..."
  $zipPath = Join-Path $env:TEMP "capitan-gold-python.zip"
  $downloadUrl = "https://www.python.org/ftp/python/$PythonVersion/python-$PythonVersion-embed-amd64.zip"
  Download-File $downloadUrl $zipPath
  $actualHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actualHash -ne $PythonSha256) {
    throw "La firma SHA-256 del paquete de Python no coincide; se cancelo la instalacion."
  }
  New-Item -ItemType Directory -Path $pythonDirectory -Force | Out-Null
  Expand-Archive -LiteralPath $zipPath -DestinationPath $pythonDirectory -Force
  Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
  if (-not (Test-Executable $pythonExe @("-c", "import sys; print(sys.version)"))) {
    throw "Python se descargo, pero no pudo iniciarse."
  }
  return $pythonExe
}

function Install-Ngrok {
  $ngrokDirectory = Join-Path $InstallPath "tools\ngrok"
  $ngrokExe = Join-Path $ngrokDirectory "ngrok.exe"
  if (Test-Executable $ngrokExe @("version")) {
    Write-Install "ngrok ya esta instalado."
    return
  }

  Write-Install "Descargando ngrok oficial..."
  $zipPath = Join-Path $env:TEMP "capitan-gold-ngrok.zip"
  Download-File `
    "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-windows-amd64.zip" `
    $zipPath
  New-Item -ItemType Directory -Path $ngrokDirectory -Force | Out-Null
  Expand-Archive -LiteralPath $zipPath -DestinationPath $ngrokDirectory -Force
  Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
  if (-not (Test-Executable $ngrokExe @("version"))) {
    throw "ngrok se descargo, pero no pudo iniciarse."
  }
}

function Remove-OldShortcuts {
  $desktop = [Environment]::GetFolderPath("Desktop")
  foreach ($name in @("Capitan Gold.lnk", "Capitan Gold Internet.lnk")) {
    $shortcut = Join-Path $desktop $name
    if (Test-Path -LiteralPath $shortcut) {
      Remove-Item -LiteralPath $shortcut -Force
    }
  }
}

try {
  New-Item -ItemType Directory -Path $DependencyRoot -Force | Out-Null
  $gitExe = Get-Git
  Write-Install "Git listo."

  if (Test-Path -LiteralPath $InstallPath) {
    if (-not (Test-Path -LiteralPath (Join-Path $InstallPath ".git"))) {
      throw "La carpeta de destino ya existe y no es una instalacion valida: $InstallPath"
    }
    Write-Install "La aplicacion ya esta instalada. Buscando actualizaciones..."
    & $gitExe -C $InstallPath fetch --quiet origin main
    if ($LASTEXITCODE -ne 0) { throw "No se pudo consultar la version de GitHub." }
    & $gitExe -C $InstallPath reset --hard origin/main
    if ($LASTEXITCODE -ne 0) { throw "No se pudo actualizar la instalacion existente." }
  } else {
    $parent = Split-Path -Parent $InstallPath
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    Write-Install "Descargando solamente el programa, sin historiales anteriores..."
    & $gitExe clone `
      --filter=blob:none `
      --depth 1 `
      --single-branch `
      --branch main `
      --no-checkout `
      $RepositoryUrl `
      $InstallPath
    if ($LASTEXITCODE -ne 0) { throw "Git no pudo descargar el programa." }

    & $gitExe -C $InstallPath sparse-checkout init --no-cone
    & $gitExe -C $InstallPath sparse-checkout set --no-cone `
      "/*" `
      "!/data/" `
      "!/tools/node/" `
      "!/tools/cloudflared/" `
      "!/tools/cloudflare-worker/" `
      "!/tools/backups/" `
      "!/tools/logs/" `
      "!/frontend/node_modules/"
    if ($LASTEXITCODE -ne 0) { throw "No se pudo preparar la instalacion liviana." }
    & $gitExe -C $InstallPath checkout main
    if ($LASTEXITCODE -ne 0) { throw "No se pudo finalizar la descarga." }
  }

  $pythonExe = Install-PortablePython
  Install-Ngrok
  Remove-OldShortcuts

  $serverPath = Join-Path $InstallPath "server.py"
  $frontendIndex = Join-Path $InstallPath "frontend\dist\frontend\browser\index.html"
  if (-not (Test-Path -LiteralPath $frontendIndex)) {
    throw "La version descargada no contiene el panel web compilado."
  }
  & $pythonExe -m py_compile $serverPath
  if ($LASTEXITCODE -ne 0) {
    throw "El servidor descargado contiene un error."
  }

  Write-Host ""
  Write-Install "Instalacion completada en: $InstallPath"
  Write-Install "Dependencias listas: Git, Python y ngrok."
  Write-Install "No se crearon accesos directos."
  Write-Install "Los meses anteriores no fueron descargados."

  if (-not $NoLaunch) {
    Write-Install "Iniciando el servidor..."
    Start-Process -FilePath (Join-Path $InstallPath "Iniciar Barberia.cmd") `
      -ArgumentList @("-NoBrowser") `
      -WorkingDirectory $InstallPath
    $serverReady = $false
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
      Start-Sleep -Milliseconds 300
      if (Get-NetTCPConnection -LocalPort 8000 -State Listen -ErrorAction SilentlyContinue) {
        $serverReady = $true
        break
      }
    }
    if (-not $serverReady) {
      throw "El programa se instalo, pero el servidor no alcanzo a iniciar."
    }
    Start-Process "http://localhost:8000/admin"
  }
  exit 0
} catch {
  Write-Host ""
  Write-Host "No se pudo instalar Capitan Gold:" -ForegroundColor Red
  Write-Host $_.Exception.Message -ForegroundColor Red
  exit 1
}
