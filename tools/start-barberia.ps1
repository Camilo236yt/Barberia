param(
  [switch]$NoBrowser,
  [switch]$NoPause,
  [switch]$CheckOnly,
  [switch]$Internet,
  [switch]$ConfigureNgrok,
  [switch]$SkipUpdateCheck
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
$PythonVersion = "3.13.14"
$PythonSha256 = "90b4e5b9898b72d744650524bff92377c367f44bd5fbd09e3148656c080ad907"

function Write-Step($Message) {
  Write-Host "[Barberia] $Message"
}

function Invoke-UpdateCheck {
  $updater = Join-Path $AppRoot "tools\update-barberia.ps1"
  if (-not (Test-Path -LiteralPath $updater)) {
    Write-Step "No se encontro el comprobador de actualizaciones; se continuara normalmente."
    return
  }

  Write-Step "Buscando actualizaciones en GitHub..."
  $windowsPowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
  & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File "`"$updater`"" -AppRoot "`"$AppRoot`""
}

function Install-PortablePythonIfMissing {
  $pythonDirectory = Join-Path $AppRoot "tools\python"
  $pythonExe = Join-Path $pythonDirectory "python.exe"
  if (Test-Path -LiteralPath $pythonExe) {
    return
  }

  Write-Step "Python portatil no esta disponible. Recuperandolo automaticamente..."
  $downloadPath = Join-Path $env:TEMP "capitan-gold-python.zip"
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest `
      -Uri "https://www.python.org/ftp/python/$PythonVersion/python-$PythonVersion-embed-amd64.zip" `
      -OutFile $downloadPath `
      -UseBasicParsing
    $actualHash = (Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $PythonSha256) {
      throw "La firma de seguridad del paquete de Python no coincide."
    }
    New-Item -ItemType Directory -Path $pythonDirectory -Force | Out-Null
    Expand-Archive -LiteralPath $downloadPath -DestinationPath $pythonDirectory -Force
  } finally {
    Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
  }
}

function Find-Python {
  $portablePython = Join-Path $AppRoot "tools\python\python.exe"
  try {
    Install-PortablePythonIfMissing
  } catch {
    Write-Step "No se pudo recuperar Python portatil: $($_.Exception.Message)"
  }
  if (Test-Path -LiteralPath $portablePython) {
    try {
      & $portablePython -c "import sys; print(sys.version)" | Out-Null
      return [pscustomobject]@{ File = $portablePython; Args = @() }
    } catch {
    }
  }
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
  $frontend = Join-Path $AppRoot "frontend"
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
    $npm = Find-Npm
    if (-not $npm) {
      if (Test-Path $index) {
        Write-Step "Usando el panel precompilado optimizado."
        return
      }
      throw "Falta el panel compilado y no se encontro Node/npm para crearlo."
    }

    $nodeModules = Join-Path $frontend "node_modules"
    $dependencyStamp = Join-Path $nodeModules ".package-lock.json"
    $packageLock = Join-Path $frontend "package-lock.json"
    $needsDependencies = -not (Test-Path $nodeModules)
    if (-not $needsDependencies -and (Test-Path $packageLock)) {
      $needsDependencies = -not (Test-Path $dependencyStamp) -or
        (Get-Item $packageLock).LastWriteTimeUtc -gt (Get-Item $dependencyStamp).LastWriteTimeUtc
    }
    if ($needsDependencies) {
      Write-Step "Instalando dependencias del panel..."
      & $npm install --prefix $frontend
      if ($LASTEXITCODE -ne 0) {
        throw "No se pudieron instalar las dependencias de Angular."
      }
    }

    Write-Step "Compilando el panel administrativo..."
    & $npm run build --prefix $frontend
    if ($LASTEXITCODE -ne 0) {
      throw "Angular no pudo compilar el panel."
    }
  }
}

function Install-NgrokIfMissing {
  if (Test-Path -LiteralPath $NgrokExe) {
    return
  }
  $ngrokDirectory = Split-Path -Parent $NgrokExe
  $downloadPath = Join-Path $env:TEMP "ngrok-capitan-gold.zip"
  New-Item -ItemType Directory -Path $ngrokDirectory -Force | Out-Null
  Write-Step "Descargando el componente para el acceso online..."
  Invoke-WebRequest `
    -Uri "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-windows-amd64.zip" `
    -OutFile $downloadPath `
    -UseBasicParsing
  Expand-Archive -LiteralPath $downloadPath -DestinationPath $ngrokDirectory -Force
  Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
  if (-not (Test-Path -LiteralPath $NgrokExe)) {
    throw "No se pudo instalar ngrok."
  }
}

function Test-NgrokProfileConfiguration {
  $previousErrorPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = "Continue"
    & $NgrokExe config check *> $null
    return $LASTEXITCODE -eq 0
  } finally {
    $ErrorActionPreference = $previousErrorPreference
  }
}

function Read-SecretText($Prompt) {
  $secureValue = Read-Host $Prompt -AsSecureString
  $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureValue)
  try {
    return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
  } finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
  }
}

function Initialize-NgrokConfiguration([switch]$Force) {
  Install-NgrokIfMissing

  if (-not $Force -and (Test-Path -LiteralPath $NgrokTokenPath)) {
    $savedToken = (Get-Content -LiteralPath $NgrokTokenPath -Raw).Trim()
    if ($savedToken) {
      return [pscustomobject]@{ Token = $savedToken; Source = "local" }
    }
  }
  if (-not $Force -and (Test-NgrokProfileConfiguration)) {
    return [pscustomobject]@{ Token = ""; Source = "profile" }
  }

  Write-Host ""
  Write-Step "ngrok necesita vincular esta computadora con la cuenta."
  Write-Step "Se abrira la pagina oficial para copiar el authtoken."
  try {
    Start-Process "https://dashboard.ngrok.com/get-started/your-authtoken"
  } catch {
  }
  $token = (Read-SecretText "Pega el authtoken de ngrok y presiona Enter").Trim()
  if ($token.Length -lt 20 -or $token -match "\s") {
    throw "El authtoken de ngrok esta vacio o no tiene un formato valido."
  }

  $previousErrorPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = "Continue"
    & $NgrokExe config add-authtoken $token | Out-Null
    $configExitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorPreference
    $token = $null
  }
  if ($configExitCode -ne 0 -or -not (Test-NgrokProfileConfiguration)) {
    throw "ngrok no pudo guardar o validar el authtoken."
  }
  Remove-Item -LiteralPath $NgrokTokenPath -Force -ErrorAction SilentlyContinue
  Write-Step "Configuracion de ngrok guardada correctamente."
  return [pscustomobject]@{ Token = ""; Source = "profile" }
}

function Invoke-Ngrok($Arguments, [switch]$AllowFailure) {
  $previousPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = "Continue"
    $lines = @(& $NgrokExe @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousPreference
  }
  $text = (($lines | ForEach-Object { "$_" }) -join [Environment]::NewLine).Trim()
  if ($exitCode -ne 0 -and -not $AllowFailure) {
    throw $(if ($text) { $text } else { "ngrok termino con el codigo $exitCode." })
  }
  return [pscustomobject]@{ ExitCode = $exitCode; Text = $text }
}

function Initialize-NgrokApiConfiguration {
  $test = Invoke-Ngrok @("api", "tunnel-sessions", "list", "--limit", "1") -AllowFailure
  if ($test.ExitCode -eq 0) {
    return
  }

  Write-Host ""
  Write-Step "Para cerrar la sesion remota anterior, ngrok necesita su API key una sola vez."
  Write-Step "Se abrira la pagina oficial. Copia la API key, no el authtoken."
  try {
    Start-Process "https://dashboard.ngrok.com/api"
  } catch {
  }
  $apiKey = (Read-SecretText "Pega la API key de ngrok y presiona Enter").Trim()
  if ($apiKey.Length -lt 20 -or $apiKey -match "\s") {
    throw "La API key de ngrok esta vacia o no tiene un formato valido."
  }
  try {
    $saved = Invoke-Ngrok @("config", "add-api-key", $apiKey) -AllowFailure
  } finally {
    $apiKey = $null
  }
  if ($saved.ExitCode -ne 0) {
    throw "ngrok no pudo guardar la API key: $($saved.Text)"
  }
  $test = Invoke-Ngrok @("api", "tunnel-sessions", "list", "--limit", "1") -AllowFailure
  if ($test.ExitCode -ne 0) {
    throw "ngrok no pudo validar la API key."
  }
}

function Stop-RemoteNgrokEndpoint($EndpointUrl) {
  Initialize-NgrokApiConfiguration
  Write-Step "Cerrando la sesion remota anterior de ngrok..."

  $listResult = Invoke-Ngrok @("api", "endpoints", "list") -AllowFailure
  if ($listResult.ExitCode -ne 0) {
    throw "No se pudieron consultar las sesiones de ngrok: $($listResult.Text)"
  }
  try {
    $endpointList = $listResult.Text | ConvertFrom-Json
  } catch {
    throw "ngrok devolvio una lista de sesiones no valida."
  }
  $targetUrl = "$EndpointUrl".TrimEnd("/")
  $sessionIds = @(
    @($endpointList.endpoints) |
      Where-Object { "$($_.url)".TrimEnd("/") -eq $targetUrl } |
      ForEach-Object { $_.tunnel_session.id } |
      Where-Object { $_ } |
      Sort-Object -Unique
  )
  if (-not $sessionIds.Count) {
    throw "No se encontro la sesion que mantiene ocupado $targetUrl."
  }
  foreach ($sessionId in $sessionIds) {
    $stopResult = Invoke-Ngrok @("api", "tunnel-sessions", "stop", "$sessionId") -AllowFailure
    if ($stopResult.ExitCode -ne 0) {
      throw "No se pudo cerrar la sesion anterior de ngrok: $($stopResult.Text)"
    }
  }
  Start-Sleep -Seconds 2
}

function Find-NgrokEndpointProcess {
  $expectedPath = [System.IO.Path]::GetFullPath($NgrokExe)
  $matches = @()
  foreach ($processInfo in Get-CimInstance Win32_Process -ErrorAction SilentlyContinue) {
    if (-not $processInfo.ExecutablePath -or -not $processInfo.CommandLine) {
      continue
    }
    $processPath = [System.IO.Path]::GetFullPath($processInfo.ExecutablePath)
    $servesHttp = $processInfo.CommandLine -match "(^|\s)http(\s|$)"
    $usesPort = $processInfo.CommandLine -match "(^|\s)$Port(\s|$)"
    if ($processPath -eq $expectedPath -and $servesHttp -and $usesPort) {
      $parentIsRunning = $null -ne (
        Get-Process -Id $processInfo.ParentProcessId -ErrorAction SilentlyContinue
      )
      $matches += [pscustomobject]@{
        Process = Get-Process -Id $processInfo.ProcessId -ErrorAction SilentlyContinue
        ParentProcessId = $processInfo.ParentProcessId
        IsOrphan = -not $parentIsRunning
      }
    }
  }
  return @($matches | Where-Object { $_.Process })
}

function Test-AppLauncherProcess($ProcessId) {
  if (-not $ProcessId -or $ProcessId -eq $PID) {
    return $false
  }
  $processInfo = Get-CimInstance Win32_Process `
    -Filter "ProcessId = $ProcessId" `
    -ErrorAction SilentlyContinue
  if (-not $processInfo -or -not $processInfo.CommandLine) {
    return $false
  }
  $launcherPath = Join-Path $AppRoot "tools\start-barberia.ps1"
  return $processInfo.CommandLine.IndexOf(
    $launcherPath,
    [StringComparison]::OrdinalIgnoreCase
  ) -ge 0
}

function Find-AppLauncherProcessIds {
  $launcherPath = Join-Path $AppRoot "tools\start-barberia.ps1"
  return @(
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
      Where-Object {
        $_.ProcessId -ne $PID -and
        $_.CommandLine -and
        $_.CommandLine.IndexOf(
          $launcherPath,
          [StringComparison]::OrdinalIgnoreCase
        ) -ge 0
      } |
      ForEach-Object { $_.ProcessId } |
      Sort-Object -Unique
  )
}

function Test-AppServerProcess($ProcessId, $PythonFile) {
  if (-not $ProcessId) {
    return $false
  }
  $processInfo = Get-CimInstance Win32_Process `
    -Filter "ProcessId = $ProcessId" `
    -ErrorAction SilentlyContinue
  if (
    -not $processInfo -or
    -not $processInfo.ExecutablePath -or
    -not $processInfo.CommandLine -or
    $processInfo.CommandLine -notmatch "(^|[\\/\s`"'])server\.py([`"'\s]|$)"
  ) {
    return $false
  }
  try {
    $processPath = [System.IO.Path]::GetFullPath($processInfo.ExecutablePath)
    $expectedPython = [System.IO.Path]::GetFullPath($PythonFile)
    $normalizedRoot = [System.IO.Path]::GetFullPath($AppRoot).TrimEnd("\") + "\"
    $usesAppPython = (
      $processPath.Equals($expectedPython, [StringComparison]::OrdinalIgnoreCase) -and
      $expectedPython.StartsWith($normalizedRoot, [StringComparison]::OrdinalIgnoreCase)
    )
    $mentionsAppRoot = $processInfo.CommandLine.IndexOf(
      $AppRoot,
      [StringComparison]::OrdinalIgnoreCase
    ) -ge 0
    $hasAppLauncher = Test-AppLauncherProcess $processInfo.ParentProcessId
    return $usesAppPython -or $mentionsAppRoot -or $hasAppLauncher
  } catch {
    return $false
  }
}

function Stop-PreviousAppSession($PythonFile) {
  $existingTunnels = @(Find-NgrokEndpointProcess)
  $launcherIds = [System.Collections.Generic.HashSet[int]]::new()
  foreach ($launcherId in @(Find-AppLauncherProcessIds)) {
    if ($launcherId -and $launcherId -ne $PID) {
      [void]$launcherIds.Add([int]$launcherId)
    }
  }
  foreach ($tunnel in $existingTunnels) {
    if ($tunnel.ParentProcessId -and $tunnel.ParentProcessId -ne $PID) {
      [void]$launcherIds.Add([int]$tunnel.ParentProcessId)
    }
  }
  $listener = Get-PortListener
  $foundPreviousSession = $existingTunnels.Count -gt 0 -or $launcherIds.Count -gt 0

  if ($listener -and (Test-AppServerProcess $listener.OwningProcess $PythonFile)) {
    $foundPreviousSession = $true
    Stop-Process -Id $listener.OwningProcess -Force -ErrorAction SilentlyContinue
  }

  if ($foundPreviousSession) {
    Write-Step "Cerrando la instancia anterior de Capitan Gold..."
  }

  # El iniciador anterior detecta el cierre del servidor y apaga su propio tunel.
  for ($attempt = 0; $attempt -lt 12; $attempt++) {
    if (-not (Get-PortListener) -and -not @(Find-NgrokEndpointProcess).Count) {
      break
    }
    Start-Sleep -Milliseconds 250
  }

  foreach ($tunnel in @(Find-NgrokEndpointProcess)) {
    if ($tunnel.ParentProcessId -and $tunnel.ParentProcessId -ne $PID) {
      [void]$launcherIds.Add([int]$tunnel.ParentProcessId)
    }
    Stop-Process -Id $tunnel.Process.Id -Force -ErrorAction SilentlyContinue
  }

  $listener = Get-PortListener
  if ($listener -and (Test-AppServerProcess $listener.OwningProcess $PythonFile)) {
    Stop-Process -Id $listener.OwningProcess -Force -ErrorAction SilentlyContinue
  }

  Start-Sleep -Milliseconds 400
  foreach ($launcherId in $launcherIds) {
    if (Test-AppLauncherProcess $launcherId) {
      Stop-Process -Id $launcherId -Force -ErrorAction SilentlyContinue
    }
  }

  Remove-Item -LiteralPath $NgrokPublicUrlPath -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $OnlineLinkPath -Force -ErrorAction SilentlyContinue
}

function Start-NgrokTunnel($StdoutLog, $StderrLog) {
  Set-Content -LiteralPath $StdoutLog -Value "" -Encoding UTF8
  Set-Content -LiteralPath $StderrLog -Value "" -Encoding UTF8
  return Start-Process -FilePath $NgrokExe `
    -ArgumentList @("http", "$Port") `
    -WorkingDirectory $AppRoot `
    -WindowStyle Hidden `
    -RedirectStandardOutput $StdoutLog `
    -RedirectStandardError $StderrLog `
    -PassThru
}

function Wait-NgrokPublicUrl($TunnelProcess) {
  for ($attempt = 0; $attempt -lt 40; $attempt++) {
    if ($TunnelProcess -and $TunnelProcess.HasExited) {
      return ""
    }
    try {
      $response = Invoke-RestMethod -Uri "http://127.0.0.1:4040/api/tunnels" -TimeoutSec 2
      $tunnel = @($response.tunnels) |
        Where-Object {
          $_.public_url -like "https://*" -and
          "$($_.config.addr)" -match "(localhost|127\.0\.0\.1):$Port/?$"
        } |
        Select-Object -First 1
      if ($tunnel.public_url) {
        return "$($tunnel.public_url)".TrimEnd("/")
      }
    } catch {
    }
    Start-Sleep -Milliseconds 250
  }
  return ""
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
  Write-Host "Hasta diez dispositivos pueden supervisar y cambiar entre ambas barberias."
  Write-Host "========================================"
  Write-Host ""
}

try {
  Set-Location $AppRoot
  if (-not (Test-Path "server.py")) {
    throw "No se encontro server.py en $AppRoot."
  }

  if ($ConfigureNgrok) {
    Initialize-NgrokConfiguration -Force | Out-Null
    Write-Step "ngrok quedo listo. Ya puedes usar Iniciar Barberia Internet.cmd."
    exit 0
  }

  if (-not $SkipUpdateCheck) {
    Invoke-UpdateCheck
  }

  Build-Frontend
  $python = Find-Python
  if (-not $python) {
    throw "No se encontro Python 3. Instalalo y vuelve a ejecutar este archivo."
  }

  Write-Step "Validando el servidor..."
  $pythonArgs = @($python.Args | ForEach-Object { [string]$_ })
  & $python.File @pythonArgs "-m" "py_compile" "server.py"
  if ($LASTEXITCODE -ne 0) {
    throw "server.py contiene un error."
  }

  if (-not $CheckOnly) {
    Stop-PreviousAppSession $python.File
  }

  $listener = Get-PortListener
  if ($listener -and -not $CheckOnly) {
    throw "El puerto $Port sigue ocupado por otro programa y no se puede iniciar Capitan Gold."
  }
  if ($CheckOnly) {
    Show-Accesses $(Get-OnlineAdminLink)
    Write-Step $(if ($listener) { "El servidor ya esta activo." } else { "El sistema esta listo para iniciar." })
    exit 0
  }

  if ($Internet) {
    $env:CAPITAN_GOLD_INTERNET = "1"
  } else {
    Remove-Item Env:CAPITAN_GOLD_INTERNET -ErrorAction SilentlyContinue
  }

  $serverProcess = $null
  if (-not $listener) {
    Write-Step "Iniciando servidor..."
    $serverArguments = [System.Collections.Generic.List[string]]::new()
    foreach ($pythonArg in $pythonArgs) {
      [void]$serverArguments.Add($pythonArg)
    }
    [void]$serverArguments.Add("server.py")
    $serverProcess = Start-Process -FilePath $python.File `
      -ArgumentList $serverArguments.ToArray() `
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
  $ownsTunnelProcess = $false
  try {
    if ($Internet) {
      $ngrokConfiguration = Initialize-NgrokConfiguration
      if ($ngrokConfiguration.Token) {
        $env:NGROK_AUTHTOKEN = $ngrokConfiguration.Token
      } else {
        Remove-Item Env:NGROK_AUTHTOKEN -ErrorAction SilentlyContinue
      }
      $logDir = Join-Path $AppRoot "tools\logs"
      New-Item -ItemType Directory -Path $logDir -Force | Out-Null
      $stdoutLog = Join-Path $logDir "admin-online-out.log"
      $stderrLog = Join-Path $logDir "admin-online-err.log"

      Write-Step "Creando el nuevo enlace administrativo online..."
      $tunnelProcess = Start-NgrokTunnel $stdoutLog $stderrLog
      $ownsTunnelProcess = $true

      $ngrokPublicUrl = Wait-NgrokPublicUrl $tunnelProcess
      if (-not $ngrokPublicUrl) {
        $ngrokError = if (Test-Path -LiteralPath $stderrLog) {
          ("$(Get-Content -LiteralPath $stderrLog -Raw)").Trim()
        } else {
          ""
        }
        if ($ngrokError -match "ERR_NGROK_334") {
          $busyEndpoint = [regex]::Match(
            $ngrokError,
            "https://[A-Za-z0-9.-]+"
          ).Value
          if (-not $busyEndpoint) {
            throw "ngrok informo una sesion anterior, pero no indico cual enlace esta ocupado."
          }
          Stop-RemoteNgrokEndpoint $busyEndpoint
          Write-Step "Creando nuevamente el enlace online..."
          $tunnelProcess = Start-NgrokTunnel $stdoutLog $stderrLog
          $ngrokPublicUrl = Wait-NgrokPublicUrl $tunnelProcess
          if (-not $ngrokPublicUrl) {
            $ngrokError = if (Test-Path -LiteralPath $stderrLog) {
              ("$(Get-Content -LiteralPath $stderrLog -Raw)").Trim()
            } else {
              ""
            }
          }
        }
        if ($ngrokError) {
          if (-not $ngrokPublicUrl) {
            throw "ngrok no pudo crear el enlace online: $ngrokError"
          }
        }
        if (-not $ngrokPublicUrl) {
          throw "ngrok no pudo crear el enlace online. Ejecuta Configurar Ngrok.cmd para renovar el acceso."
        }
      }
      [System.IO.File]::WriteAllText(
        $NgrokPublicUrlPath,
        $ngrokPublicUrl + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false)
      )
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
      Write-Step "Modo local activo: ngrok no se inicia con este archivo."
      Write-Step "Para crear el enlace online usa Iniciar Barberia Internet.cmd."
      Show-Accesses
    }

    if (-not $NoBrowser) {
      Start-Process $LocalAdminUrl
    }
    Write-Step $(if ($Internet) {
      "Modo Internet activo. Para apagar el servidor, cierra esta ventana."
    } else {
      "Al cerrar la pestaña local se apagara tambien esta ventana."
    })
    while (Get-PortListener) {
      if ($serverProcess -and $serverProcess.HasExited) {
        break
      }
      if ($tunnelProcess -and $tunnelProcess.HasExited) {
        throw "El enlace online se cerro inesperadamente."
      }
      Start-Sleep -Milliseconds 600
    }
  } finally {
    if ($ownsTunnelProcess -and $tunnelProcess -and -not $tunnelProcess.HasExited) {
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
