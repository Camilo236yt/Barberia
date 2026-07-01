param(
  [switch]$NoBrowser,
  [switch]$NoPause,
  [switch]$CheckOnly,
  [switch]$Internet
)

$ErrorActionPreference = "Stop"
$Port = 8000
$AppRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$LocalAdminUrl = "http://localhost:$Port/admin"
$NgrokExe = Join-Path $AppRoot "tools\ngrok\ngrok.exe"
$NgrokTokenPath = Join-Path $AppRoot "tools\ngrok\authtoken.txt"
$NgrokPublicUrlPath = Join-Path $AppRoot "tools\ngrok\public-url.txt"
$OnlineTokenPath = Join-Path $AppRoot "data\admin-online-token.txt"
$OnlineLinkPath = Join-Path $AppRoot "LINK_ADMIN_ONLINE.txt"

function Write-Step($Message) {
  Write-Host "[Barberia] $Message"
}

function Find-Python {
  foreach ($candidate in @("python", "py")) {
    $command = Get-Command $candidate -ErrorAction SilentlyContinue
    if (-not $command) {
      continue
    }
    try {
      if ($candidate -eq "py") {
        & $command.Source -3 -c "import sys; print(sys.version)" | Out-Null
        return [pscustomobject]@{ File = $command.Source; Args = @("-3") }
      }
      & $command.Source -c "import sys; print(sys.version)" | Out-Null
      return [pscustomobject]@{ File = $command.Source; Args = @() }
    } catch {
    }
  }
  return $null
}

function Find-Npm {
  $portableNpm = Join-Path $AppRoot "tools\node\node-v24.16.0-win-x64\npm.cmd"
  if (Test-Path $portableNpm) {
    return $portableNpm
  }
  $npm = Get-Command npm.cmd -ErrorAction SilentlyContinue
  if ($npm) {
    return $npm.Source
  }
  return $null
}

function Enable-PortableNode {
  $portableNode = Join-Path $AppRoot "tools\node\node-v24.16.0-win-x64"
  if (Test-Path $portableNode) {
    $env:Path = "$portableNode;$env:Path"
  }
}

function Build-Frontend {
  Enable-PortableNode
  $npm = Find-Npm
  if (-not $npm) {
    throw "No se encontro Node/npm. Instala Node.js o restaura tools\node."
  }

  $frontend = Join-Path $AppRoot "frontend"
  if (-not (Test-Path (Join-Path $frontend "node_modules"))) {
    Write-Step "Instalando dependencias del panel..."
    & $npm install --prefix $frontend
    if ($LASTEXITCODE -ne 0) {
      throw "No se pudieron instalar las dependencias de Angular."
    }
  }

  $index = Join-Path $frontend "dist\frontend\browser\index.html"
  $needsBuild = -not (Test-Path $index)
  if (-not $needsBuild) {
    $buildTime = (Get-Item $index).LastWriteTimeUtc
    $newerSource = Get-ChildItem (Join-Path $frontend "src"), (Join-Path $frontend "public") -File -Recurse |
      Where-Object { $_.LastWriteTimeUtc -gt $buildTime } |
      Select-Object -First 1
    $needsBuild = $null -ne $newerSource
  }

  if ($needsBuild) {
    Write-Step "Compilando el panel administrativo..."
    & $npm run build --prefix $frontend
    if ($LASTEXITCODE -ne 0) {
      throw "Angular no pudo compilar el panel."
    }
  }
}

function Get-PortListener {
  return Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
    Select-Object -First 1
}

function Get-OnlineAdminLink {
  if (-not (Test-Path $NgrokPublicUrlPath) -or -not (Test-Path $OnlineTokenPath)) {
    return ""
  }
  $baseUrl = (Get-Content -LiteralPath $NgrokPublicUrlPath -Raw).Trim().TrimEnd("/")
  $adminToken = (Get-Content -LiteralPath $OnlineTokenPath -Raw).Trim()
  if (-not $baseUrl -or -not $adminToken) {
    return ""
  }
  return "$baseUrl/admin/online?token=$adminToken"
}

function Show-Accesses($OnlineUrl = "") {
  Write-Host ""
  Write-Host "========================================"
  Write-Host "BARBERIA CONTROL"
  Write-Host ""
  Write-Host "ADMINISTRADOR EN LA COMPUTADORA PRINCIPAL:"
  Write-Host $LocalAdminUrl
  Write-Host ""
  if ($OnlineUrl) {
    Write-Host "NUEVO ENLACE PARA EL ADMINISTRADOR ONLINE:"
    Write-Host $OnlineUrl
    Write-Host ""
  }
  Write-Host "Cada administrador debe seleccionar una barberia diferente."
  Write-Host "========================================"
  Write-Host ""
}

try {
  Set-Location $AppRoot
  if (-not (Test-Path "server.py")) {
    throw "No se encontro server.py en $AppRoot."
  }

  Build-Frontend
  $python = Find-Python
  if (-not $python) {
    throw "No se encontro Python 3. Instalalo y vuelve a ejecutar este archivo."
  }

  Write-Step "Validando el servidor..."
  & $python.File @($python.Args + @("-m", "py_compile", "server.py"))
  if ($LASTEXITCODE -ne 0) {
    throw "server.py contiene un error."
  }

  $listener = Get-PortListener
  if ($CheckOnly) {
    Show-Accesses $(Get-OnlineAdminLink)
    Write-Step $(if ($listener) { "El servidor ya esta activo." } else { "El sistema esta listo para iniciar." })
    exit 0
  }

  $serverProcess = $null
  if (-not $listener) {
    Write-Step "Iniciando servidor..."
    $serverProcess = Start-Process -FilePath $python.File `
      -ArgumentList @($python.Args + @("server.py")) `
      -WorkingDirectory $AppRoot `
      -NoNewWindow `
      -PassThru

    for ($attempt = 0; $attempt -lt 20; $attempt++) {
      Start-Sleep -Milliseconds 350
      if (Get-PortListener) {
        break
      }
      if ($serverProcess.HasExited) {
        throw "El servidor termino antes de iniciar."
      }
    }

    if (-not (Get-PortListener)) {
      Stop-Process -Id $serverProcess.Id -Force -ErrorAction SilentlyContinue
      throw "El servidor no respondio en el puerto $Port."
    }
  } else {
    Write-Step "El servidor ya esta abierto en el puerto $Port."
  }

  $tunnelProcess = $null
  try {
    if ($Internet) {
      if (-not (Test-Path $NgrokExe)) {
        throw "No se encontro tools\ngrok\ngrok.exe."
      }
      if (-not (Test-Path $NgrokTokenPath) -or -not (Test-Path $NgrokPublicUrlPath)) {
        throw "Falta la configuracion de ngrok en tools\ngrok."
      }

      $ngrokToken = (Get-Content -LiteralPath $NgrokTokenPath -Raw).Trim()
      $ngrokPublicUrl = (Get-Content -LiteralPath $NgrokPublicUrlPath -Raw).Trim().TrimEnd("/")
      $ngrokHost = ([uri]$ngrokPublicUrl).Host
      $env:NGROK_AUTHTOKEN = $ngrokToken
      $logDir = Join-Path $AppRoot "tools\logs"
      New-Item -ItemType Directory -Path $logDir -Force | Out-Null
      $stdoutLog = Join-Path $logDir "admin-online-out.log"
      $stderrLog = Join-Path $logDir "admin-online-err.log"

      Write-Step "Creando el nuevo enlace administrativo online..."
      $tunnelProcess = Start-Process -FilePath $NgrokExe `
        -ArgumentList @("http", "--url=$ngrokHost", "$Port") `
        -WorkingDirectory $AppRoot `
        -WindowStyle Hidden `
        -RedirectStandardOutput $stdoutLog `
        -RedirectStandardError $stderrLog `
        -PassThru
      Start-Sleep -Seconds 2
      if ($tunnelProcess.HasExited) {
        throw "ngrok no pudo crear el enlace online. Revisa $stderrLog."
      }

      $onlineUrl = Get-OnlineAdminLink
      if (-not $onlineUrl) {
        throw "No se pudo construir el enlace administrativo online."
      }
      Set-Content -LiteralPath $OnlineLinkPath -Value @(
        "ENLACE ADMINISTRATIVO ONLINE:",
        $onlineUrl,
        "",
        "Este enlace es privado. No lo compartas con clientes ni barberos."
      ) -Encoding UTF8
      try { Set-Clipboard -Value $onlineUrl } catch {}
      Show-Accesses $onlineUrl
    } else {
      Show-Accesses
    }

    if (-not $NoBrowser) {
      Start-Process $LocalAdminUrl
    }
    Write-Step "Cierra esta ventana o usa Ctrl+C para apagar el sistema."
    if ($tunnelProcess) {
      Wait-Process -Id $tunnelProcess.Id
    } elseif ($serverProcess) {
      Wait-Process -Id $serverProcess.Id
    } elseif (-not $NoPause) {
      Read-Host "Presiona Enter para cerrar esta ventana"
    }
  } finally {
    if ($tunnelProcess -and -not $tunnelProcess.HasExited) {
      Stop-Process -Id $tunnelProcess.Id -Force -ErrorAction SilentlyContinue
    }
    if ($serverProcess -and -not $serverProcess.HasExited) {
      Stop-Process -Id $serverProcess.Id -Force -ErrorAction SilentlyContinue
    }
  }
} catch {
  Write-Host ""
  Write-Host "No se pudo iniciar Barberia Control:" -ForegroundColor Red
  Write-Host $_.Exception.Message -ForegroundColor Red
  Write-Host ""
  if (-not $NoPause) {
    Read-Host "Presiona Enter para cerrar"
  }
  exit 1
}
