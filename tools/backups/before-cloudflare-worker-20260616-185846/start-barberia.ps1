param(
  [switch]$NoBrowser,
  [switch]$NoPause,
  [switch]$CheckOnly,
  [switch]$Internet
)

$ErrorActionPreference = "Stop"
$Port = 8000
$AppRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$AdminUrl = "http://localhost:$Port/admin"
$NodeVersionLine = "latest-v24.x"
$NgrokDownloadUrl = "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-windows-amd64.zip"
$NgrokTokenPath = Join-Path $AppRoot "tools\ngrok\authtoken.txt"
$NgrokPublicUrlPath = Join-Path $AppRoot "tools\ngrok\public-url.txt"
$CloudflaredUrl = "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe"
$FixedTunnelTokenPath = Join-Path $AppRoot "tools\cloudflared\tunnel-token.txt"
$FixedTunnelPublicUrlPath = Join-Path $AppRoot "tools\cloudflared\public-url.txt"
$BarberLinkPath = Join-Path $AppRoot "LINK_BARBEROS.txt"
$ManagedProcessIds = @()
$KillOnCloseJob = [IntPtr]::Zero
$ProcessGuardReady = $false

function Write-Step($Message) {
  Write-Host "[Barberia] $Message"
}

function Initialize-ProcessGuard {
  if ($script:ProcessGuardReady) {
    return
  }
  $script:ProcessGuardReady = $true

  try {
    if (-not ([System.Management.Automation.PSTypeName]"BarberiaNativeJob").Type) {
      Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class BarberiaNativeJob {
  [StructLayout(LayoutKind.Sequential)]
  public struct IO_COUNTERS {
    public UInt64 ReadOperationCount;
    public UInt64 WriteOperationCount;
    public UInt64 OtherOperationCount;
    public UInt64 ReadTransferCount;
    public UInt64 WriteTransferCount;
    public UInt64 OtherTransferCount;
  }

  [StructLayout(LayoutKind.Sequential)]
  public struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
    public Int64 PerProcessUserTimeLimit;
    public Int64 PerJobUserTimeLimit;
    public UInt32 LimitFlags;
    public UIntPtr MinimumWorkingSetSize;
    public UIntPtr MaximumWorkingSetSize;
    public UInt32 ActiveProcessLimit;
    public UIntPtr Affinity;
    public UInt32 PriorityClass;
    public UInt32 SchedulingClass;
  }

  [StructLayout(LayoutKind.Sequential)]
  public struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
    public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
    public IO_COUNTERS IoInfo;
    public UIntPtr ProcessMemoryLimit;
    public UIntPtr JobMemoryLimit;
    public UIntPtr PeakProcessMemoryUsed;
    public UIntPtr PeakJobMemoryUsed;
  }

  [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
  public static extern IntPtr CreateJobObject(IntPtr lpJobAttributes, string lpName);

  [DllImport("kernel32.dll")]
  public static extern bool SetInformationJobObject(IntPtr hJob, int JobObjectInfoClass, IntPtr lpJobObjectInfo, UInt32 cbJobObjectInfoLength);

  [DllImport("kernel32.dll")]
  public static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);

  public const UInt32 JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
  public const int JobObjectExtendedLimitInformation = 9;

  public static IntPtr CreateKillOnCloseJob() {
    IntPtr job = CreateJobObject(IntPtr.Zero, null);
    if (job == IntPtr.Zero) {
      return IntPtr.Zero;
    }

    JOBOBJECT_EXTENDED_LIMIT_INFORMATION info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
    info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;

    int length = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
    IntPtr pointer = Marshal.AllocHGlobal(length);
    try {
      Marshal.StructureToPtr(info, pointer, false);
      if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, pointer, (UInt32)length)) {
        return IntPtr.Zero;
      }
      return job;
    } finally {
      Marshal.FreeHGlobal(pointer);
    }
  }
}
"@
    }

    $script:KillOnCloseJob = [BarberiaNativeJob]::CreateKillOnCloseJob()
  } catch {
    $script:KillOnCloseJob = [IntPtr]::Zero
  }
}

function Add-ManagedProcess($Process) {
  if (-not $Process) {
    return
  }

  if ($script:ManagedProcessIds -notcontains $Process.Id) {
    $script:ManagedProcessIds += $Process.Id
  }

  Initialize-ProcessGuard
  if ($script:KillOnCloseJob -ne [IntPtr]::Zero) {
    try {
      [BarberiaNativeJob]::AssignProcessToJobObject($script:KillOnCloseJob, $Process.Handle) | Out-Null
    } catch {
      # El apagado manual en Stop-ManagedProcesses queda como respaldo.
    }
  }
}

function Stop-ManagedProcesses {
  foreach ($processId in ($script:ManagedProcessIds | Select-Object -Unique)) {
    try {
      $process = Get-Process -Id $processId -ErrorAction Stop
      if (-not $process.HasExited) {
        Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
      }
    } catch {
    }
  }
}

function Get-LocalIp {
  try {
    $socket = [System.Net.Sockets.UdpClient]::new()
    $socket.Connect("8.8.8.8", 80)
    $ip = $socket.Client.LocalEndPoint.Address.ToString()
    $socket.Close()
    return $ip
  } catch {
    return "127.0.0.1"
  }
}

function Test-PythonCommand($File, [string[]]$ExtraArgs) {
  try {
    $commandArgs = @($ExtraArgs + @("--version"))
    $output = & $File @commandArgs 2>&1
    if ($LASTEXITCODE -eq 0 -and ($output -join " ") -match "Python 3") {
      return [pscustomobject]@{
        File = $File
        Args = $ExtraArgs
        Version = ($output -join " ").Trim()
      }
    }
  } catch {
    return $null
  }
  return $null
}

function Find-Python {
  $candidates = @(
    @{ File = "py"; Args = @("-3") },
    @{ File = "python"; Args = @() },
    @{ File = "python3"; Args = @() }
  )

  foreach ($candidate in $candidates) {
    $python = Test-PythonCommand $candidate.File $candidate.Args
    if ($python) {
      return $python
    }
  }

  $knownPaths = @(
    (Join-Path $env:LocalAppData "Programs\Python\Python313\python.exe"),
    (Join-Path $env:ProgramFiles "Python313\python.exe"),
    (Join-Path ${env:ProgramFiles(x86)} "Python313-32\python.exe")
  )

  foreach ($path in $knownPaths) {
    if ($path -and (Test-Path $path)) {
      $python = Test-PythonCommand $path @()
      if ($python) {
        return $python
      }
    }
  }

  return $null
}

function Refresh-Path {
  $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
  $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
  $env:Path = "$machinePath;$userPath"
}

function Test-NodeCommand($NodeFile) {
  try {
    $version = (& $NodeFile "--version" 2>&1) -join " "
    if ($LASTEXITCODE -eq 0 -and $version -match "^v\d+") {
      $nodeDir = Split-Path $NodeFile -Parent
      $npm = Join-Path $nodeDir "npm.cmd"
      if (-not (Test-Path $npm)) {
        $npmCommand = Get-Command npm -ErrorAction SilentlyContinue
        if ($npmCommand) {
          $npm = $npmCommand.Source
        }
      }
      if (Test-Path $npm) {
        return [pscustomobject]@{
          Node = $NodeFile
          Npm = $npm
          Dir = $nodeDir
          Version = $version.Trim()
        }
      }
    }
  } catch {
    return $null
  }
  return $null
}

function Find-Node {
  $portableRoot = Join-Path $AppRoot "tools\node"
  if (Test-Path $portableRoot) {
    $portableNode = Get-ChildItem -Path $portableRoot -Recurse -Filter node.exe -ErrorAction SilentlyContinue |
      Where-Object { $_.FullName -like "*win-x64*" } |
      Select-Object -First 1
    if ($portableNode) {
      $node = Test-NodeCommand $portableNode.FullName
      if ($node) {
        return $node
      }
    }
  }

  $nodeCommand = Get-Command node -ErrorAction SilentlyContinue
  if ($nodeCommand) {
    $node = Test-NodeCommand $nodeCommand.Source
    if ($node) {
      return $node
    }
  }

  return $null
}

function Install-NodePortable {
  Write-Step "Node no esta disponible. Descargando Node LTS portable..."
  $nodeRoot = Join-Path $AppRoot "tools\node"
  New-Item -ItemType Directory -Force -Path $nodeRoot | Out-Null

  $listing = Invoke-WebRequest -UseBasicParsing "https://nodejs.org/dist/$NodeVersionLine/" -TimeoutSec 30
  $zipHref = ($listing.Links | Where-Object { $_.href -like "*win-x64.zip" } | Select-Object -First 1 -ExpandProperty href)
  if (-not $zipHref) {
    throw "No se encontro el ZIP de Node para Windows x64."
  }

  $zipName = Split-Path $zipHref -Leaf
  $zipPath = Join-Path $nodeRoot $zipName
  $extractName = $zipName -replace "\.zip$", ""
  $extractPath = Join-Path $nodeRoot $extractName

  if (-not (Test-Path $zipPath)) {
    Invoke-WebRequest -Uri "https://nodejs.org$zipHref" -OutFile $zipPath -TimeoutSec 180
  }
  if (-not (Test-Path $extractPath)) {
    Expand-Archive -LiteralPath $zipPath -DestinationPath $nodeRoot -Force
  }

  $node = Test-NodeCommand (Join-Path $extractPath "node.exe")
  if (-not $node) {
    throw "No se pudo preparar Node portable."
  }
  return $node
}

function Test-AngularBuildNeeded {
  $frontendRoot = Join-Path $AppRoot "frontend"
  if (-not (Test-Path (Join-Path $frontendRoot "package.json"))) {
    return $false
  }

  $distIndex = Join-Path $frontendRoot "dist\frontend\browser\index.html"
  if (-not (Test-Path $distIndex)) {
    return $true
  }

  $sourceFiles = @()
  foreach ($relative in @("src", "public", "package.json", "angular.json", "tsconfig.json", "tsconfig.app.json")) {
    $path = Join-Path $frontendRoot $relative
    if (Test-Path $path -PathType Container) {
      $sourceFiles += Get-ChildItem -Path $path -Recurse -File
    } elseif (Test-Path $path -PathType Leaf) {
      $sourceFiles += Get-Item $path
    }
  }

  if (-not $sourceFiles) {
    return $false
  }

  $latestSource = ($sourceFiles | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1).LastWriteTimeUtc
  $distTime = (Get-Item $distIndex).LastWriteTimeUtc
  return $latestSource -gt $distTime
}

function Build-AngularIfNeeded {
  if (-not (Test-AngularBuildNeeded)) {
    return
  }

  $node = Find-Node
  if (-not $node) {
    $node = Install-NodePortable
  }

  Write-Step "Usando Node $($node.Version)"
  $frontendRoot = Join-Path $AppRoot "frontend"
  $env:Path = "$($node.Dir);$env:Path"

  Push-Location $frontendRoot
  try {
    if (-not (Test-Path "node_modules")) {
      Write-Step "Instalando dependencias Angular..."
      & $node.Npm install
      if ($LASTEXITCODE -ne 0) {
        throw "npm install termino con codigo $LASTEXITCODE."
      }
    }

    Write-Step "Compilando frontend Angular..."
    & $node.Npm run build
    if ($LASTEXITCODE -ne 0) {
      throw "Angular build termino con codigo $LASTEXITCODE."
    }
  } finally {
    Pop-Location
  }
}

function Test-NgrokCommand($NgrokFile) {
  try {
    $version = (& $NgrokFile "version" 2>&1) -join " "
    if ($LASTEXITCODE -eq 0 -and $version -match "ngrok") {
      return [pscustomobject]@{
        File = $NgrokFile
        Version = $version.Trim()
      }
    }
  } catch {
    return $null
  }
  return $null
}

function Find-Ngrok {
  $portablePath = Join-Path $AppRoot "tools\ngrok\ngrok.exe"
  if (Test-Path $portablePath) {
    $ngrok = Test-NgrokCommand $portablePath
    if ($ngrok) {
      return $ngrok
    }
  }

  $command = Get-Command ngrok -ErrorAction SilentlyContinue
  if ($command) {
    $ngrok = Test-NgrokCommand $command.Source
    if ($ngrok) {
      return $ngrok
    }
  }

  return $null
}

function Install-Ngrok {
  Write-Step "ngrok no esta disponible. Descargando agente portable..."
  $targetDir = Join-Path $AppRoot "tools\ngrok"
  $zipPath = Join-Path $targetDir "ngrok-v3-stable-windows-amd64.zip"
  New-Item -ItemType Directory -Force -Path $targetDir | Out-Null

  Invoke-WebRequest -Uri $NgrokDownloadUrl -OutFile $zipPath -TimeoutSec 180
  Expand-Archive -LiteralPath $zipPath -DestinationPath $targetDir -Force

  $ngrok = Test-NgrokCommand (Join-Path $targetDir "ngrok.exe")
  if (-not $ngrok) {
    throw "No se pudo preparar ngrok."
  }
  return $ngrok
}

function Get-NgrokConfig {
  if (-not (Test-Path $NgrokTokenPath)) {
    return $null
  }
  if (-not (Test-Path $NgrokPublicUrlPath)) {
    return $null
  }

  $token = (Get-Content -LiteralPath $NgrokTokenPath -Raw -ErrorAction SilentlyContinue).Trim()
  $publicUrl = (Get-Content -LiteralPath $NgrokPublicUrlPath -Raw -ErrorAction SilentlyContinue).Trim()
  if (-not $token -or -not $publicUrl) {
    return $null
  }

  return [pscustomobject]@{
    Token = $token
    PublicUrl = $publicUrl
    TokenPath = $NgrokTokenPath
    PublicUrlPath = $NgrokPublicUrlPath
  }
}

function Get-NgrokUrlHost($PublicUrl) {
  $cleanUrl = $PublicUrl.Trim().TrimEnd("/")
  $cleanUrl = $cleanUrl -replace "^https?://", ""
  $cleanUrl = $cleanUrl -replace "/barberos?$", ""
  return $cleanUrl.TrimEnd("/")
}

function Test-CloudflaredCommand($CloudflaredFile) {
  try {
    $version = (& $CloudflaredFile "--version" 2>&1) -join " "
    if ($LASTEXITCODE -eq 0 -and $version -match "cloudflared") {
      return [pscustomobject]@{
        File = $CloudflaredFile
        Version = $version.Trim()
      }
    }
  } catch {
    return $null
  }
  return $null
}

function Find-Cloudflared {
  $portablePath = Join-Path $AppRoot "tools\cloudflared\cloudflared.exe"
  if (Test-Path $portablePath) {
    $cloudflared = Test-CloudflaredCommand $portablePath
    if ($cloudflared) {
      return $cloudflared
    }
  }

  $command = Get-Command cloudflared -ErrorAction SilentlyContinue
  if ($command) {
    $cloudflared = Test-CloudflaredCommand $command.Source
    if ($cloudflared) {
      return $cloudflared
    }
  }

  return $null
}

function Install-Cloudflared {
  Write-Step "cloudflared no esta disponible. Descargando cliente de Cloudflare Tunnel..."
  $targetDir = Join-Path $AppRoot "tools\cloudflared"
  $targetPath = Join-Path $targetDir "cloudflared.exe"
  New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
  Invoke-WebRequest -Uri $CloudflaredUrl -OutFile $targetPath -TimeoutSec 180

  $cloudflared = Test-CloudflaredCommand $targetPath
  if (-not $cloudflared) {
    throw "No se pudo preparar cloudflared."
  }
  return $cloudflared
}

function Get-FixedTunnelConfig {
  if (-not (Test-Path $FixedTunnelTokenPath)) {
    return $null
  }

  $tokenText = (Get-Content -LiteralPath $FixedTunnelTokenPath -Raw -ErrorAction SilentlyContinue).Trim()
  if (-not $tokenText) {
    return $null
  }

  $token = $tokenText
  if ($tokenText -match "--token\s+['`"]?([^'`"\s]+)") {
    $token = $Matches[1]
  } elseif ($tokenText -match "cloudflared\.exe\s+service\s+install\s+['`"]?([^'`"\s]+)") {
    $token = $Matches[1]
  } elseif ($tokenText -match "cloudflared\s+service\s+install\s+['`"]?([^'`"\s]+)") {
    $token = $Matches[1]
  }

  $token = $token.Trim().Trim("'").Trim('"')
  if (-not $token) {
    return $null
  }

  $publicUrl = ""
  if (Test-Path $FixedTunnelPublicUrlPath) {
    $publicUrl = (Get-Content -LiteralPath $FixedTunnelPublicUrlPath -Raw -ErrorAction SilentlyContinue).Trim()
  }

  return [pscustomobject]@{
    Token = $token
    PublicUrl = $publicUrl
    TokenPath = $FixedTunnelTokenPath
    PublicUrlPath = $FixedTunnelPublicUrlPath
  }
}

function Get-BarberPortalUrl($PublicUrl) {
  if (-not $PublicUrl) {
    return ""
  }

  $cleanUrl = $PublicUrl.Trim().TrimEnd("/")
  if ($cleanUrl -match "/barberos?$") {
    return $cleanUrl
  }
  return "$cleanUrl/barberos"
}

function Install-Python {
  Write-Step "Python no esta instalado. Intentando instalarlo automaticamente..."

  $winget = Get-Command winget -ErrorAction SilentlyContinue
  if ($winget) {
    Write-Step "Instalando Python con winget..."
    & $winget.Source install -e --id Python.Python.3.13 --accept-package-agreements --accept-source-agreements
    Refresh-Path
    $python = Find-Python
    if ($python) {
      return $python
    }
  }

  Write-Step "winget no esta disponible o no completo la instalacion. Descargando instalador oficial..."
  $version = "3.13.5"
  $installer = Join-Path $env:TEMP "python-$version-amd64.exe"
  $url = "https://www.python.org/ftp/python/$version/python-$version-amd64.exe"

  Invoke-WebRequest -Uri $url -OutFile $installer
  $process = Start-Process -FilePath $installer -ArgumentList @(
    "/quiet",
    "InstallAllUsers=0",
    "PrependPath=1",
    "Include_launcher=1",
    "Include_pip=1",
    "SimpleInstall=1"
  ) -Wait -PassThru

  if ($process.ExitCode -ne 0) {
    throw "El instalador de Python termino con codigo $($process.ExitCode)."
  }

  Refresh-Path
  return Find-Python
}

function Invoke-Python($Python, [string[]]$PythonArgs) {
  & $Python.File @($Python.Args + $PythonArgs)
}

function Get-PortListener {
  try {
    return Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
  } catch {
    return $null
  }
}

function Get-ProcessById($ProcessId) {
  try {
    return Get-Process -Id $ProcessId -ErrorAction Stop
  } catch {
    return $null
  }
}

function Test-BarberiaServerProcess($ProcessId) {
  try {
    $processInfo = Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction Stop
    $commandLine = $processInfo.CommandLine
    if (-not $commandLine) {
      return $false
    }
    return $commandLine -match "(^|\s|`")server\.py(\s|`"|$)"
  } catch {
    return $false
  }
}

function Add-ExistingServerIfSafe($Listener) {
  if (-not $Listener) {
    return $false
  }

  if (Test-BarberiaServerProcess $Listener.OwningProcess) {
    $process = Get-ProcessById $Listener.OwningProcess
    if ($process) {
      Add-ManagedProcess $process
      return $true
    }
  }

  return $false
}

function Open-Admin {
  if (-not $NoBrowser) {
    Start-Process $AdminUrl
  }
}

function Save-BarberLink($BarberUrl, $Note) {
  $linkText = @(
    "Link para barberos (internet/datos moviles):",
    $BarberUrl,
    "",
    $Note,
    "",
    "Admin en la laptop:",
    $AdminUrl
  ) -join [Environment]::NewLine
  Set-Content -LiteralPath $BarberLinkPath -Value $linkText -Encoding UTF8
  try {
    Set-Clipboard -Value $BarberUrl
  } catch {
  }
}

function Save-BarberLinkPending {
  $linkText = @(
    "Link para barberos:",
    "Todavia no hay puente publico activo.",
    "",
    "Abre Iniciar Barberia Internet.cmd y espera a que aparezca el link HTTPS publico.",
    "Ese link se guarda y copia automaticamente para compartirlo con los barberos."
  ) -join [Environment]::NewLine
  Set-Content -LiteralPath $BarberLinkPath -Value $linkText -Encoding UTF8
}

function Show-Links($ServerPid) {
  $ip = Get-LocalIp
  $barberUrl = "http://$ip`:$Port/barberos"
  Save-BarberLinkPending

  Write-Host ""
  Write-Host "========================================"
  Write-Host "SERVIDOR ACTIVO"
  if ($ServerPid) {
    Write-Host "PID: $ServerPid"
  }
  Write-Host ""
  Write-Host "Admin/laptop:"
  Write-Host $AdminUrl
  Write-Host ""
  Write-Host "Barberos por internet/datos moviles:"
  Write-Host "Se creara un puente HTTPS publico y se guardara en LINK_BARBEROS.txt."
  Write-Host ""
  Write-Host "Prueba local Wi-Fi (no compartir para datos moviles):"
  Write-Host $barberUrl
  Write-Host ""
  Write-Host "El archivo de link para barberos queda reservado para el link publico:"
  Write-Host $BarberLinkPath
  Write-Host "========================================"
  Write-Host ""
}

function Start-ServerManaged($Python) {
  Write-Step "Arrancando servidor local..."
  $arguments = @($Python.Args + @("server.py"))
  $process = Start-Process -FilePath $Python.File -ArgumentList $arguments -WorkingDirectory $AppRoot -NoNewWindow -PassThru
  Add-ManagedProcess $process

  for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 500
    $listener = Get-PortListener
    if ($listener) {
      $listenerProcess = Get-ProcessById $listener.OwningProcess
      if ($listenerProcess) {
        Add-ManagedProcess $listenerProcess
      }
      return [pscustomobject]@{
        Process = $process
        Listener = $listener
      }
    }
    if ($process.HasExited) {
      throw "El servidor local termino antes de quedar listo."
    }
  }

  throw "El servidor local no respondio en el puerto $Port."
}

function Start-NgrokTunnel($Python, $NgrokConfig) {
  $ngrok = Find-Ngrok
  if (-not $ngrok) {
    $ngrok = Install-Ngrok
  }

  $barberUrl = Get-BarberPortalUrl $NgrokConfig.PublicUrl
  $ngrokHost = Get-NgrokUrlHost $NgrokConfig.PublicUrl
  if (-not $barberUrl -or -not $ngrokHost) {
    throw "Falta configurar el dominio publico de ngrok en $($NgrokConfig.PublicUrlPath)."
  }

  $startedServer = $null
  $listener = Get-PortListener
  if (-not $listener) {
    $startedServer = Start-ServerManaged $Python
    $listener = $startedServer.Listener
  } else {
    Add-ExistingServerIfSafe $listener | Out-Null
  }

  Show-Links $listener.OwningProcess
  Write-Step "Usando $($ngrok.Version)"
  Write-Step "Creando puente fijo ngrok..."
  Write-Host ""
  Write-Host "LINK FIJO BARBEROS:"
  Write-Host $barberUrl
  Write-Host ""
  Write-Host "Este link solo funciona mientras esta ventana y el servidor esten abiertos."
  Write-Host ""

  $logDir = Join-Path $AppRoot "tools\logs"
  New-Item -ItemType Directory -Force -Path $logDir | Out-Null
  $stdoutLog = Join-Path $logDir "ngrok-out.log"
  $stderrLog = Join-Path $logDir "ngrok-err.log"
  Remove-Item -LiteralPath $stdoutLog, $stderrLog -Force -ErrorAction SilentlyContinue

  $previousToken = $env:NGROK_AUTHTOKEN
  $env:NGROK_AUTHTOKEN = $NgrokConfig.Token
  try {
    $ngrokArgs = @("http", "--url=$ngrokHost", "$Port")
    $tunnel = Start-Process -FilePath $ngrok.File `
      -ArgumentList $ngrokArgs `
      -NoNewWindow `
      -PassThru `
      -RedirectStandardOutput $stdoutLog `
      -RedirectStandardError $stderrLog
    Add-ManagedProcess $tunnel

    Start-Sleep -Seconds 3
    $tunnel.Refresh()
    if ($tunnel.HasExited) {
      Write-Host ""
      Write-Host "ngrok se detuvo antes de publicar el link. Ultimos logs:"
      if (Test-Path $stderrLog) {
        Get-Content -LiteralPath $stderrLog -Tail 40
      }
      throw "No se pudo iniciar ngrok. Revisa el token y el dominio fijo configurado."
    }

    Save-BarberLink $barberUrl "Este link fijo de ngrok funciona con datos moviles mientras esta ventana y el servidor esten abiertos. Si el servidor esta apagado, los barberos solo deben refrescar cuando vuelvas a abrirlo."
    try {
      Set-Clipboard -Value $barberUrl
    } catch {
    }

    Write-Host "Tambien quedo guardado y copiado desde:"
    Write-Host $BarberLinkPath
    Write-Host ""
    if (-not $NoBrowser) {
      Start-Process $barberUrl
    }

    Wait-Process -Id $tunnel.Id
    Write-Host ""
    Write-Host "El puente ngrok se detuvo. Ultimos logs:"
    if (Test-Path $stderrLog) {
      Get-Content -LiteralPath $stderrLog -Tail 30
    }
  } finally {
    if ($null -eq $previousToken) {
      Remove-Item Env:\NGROK_AUTHTOKEN -ErrorAction SilentlyContinue
    } else {
      $env:NGROK_AUTHTOKEN = $previousToken
    }
    Stop-ManagedProcesses
  }
}

function Start-InternetTunnel($Python) {
  $ngrokConfig = Get-NgrokConfig
  if ($ngrokConfig) {
    Start-NgrokTunnel $Python $ngrokConfig
    return
  }

  $cloudflared = Find-Cloudflared
  if (-not $cloudflared) {
    $cloudflared = Install-Cloudflared
  }
  $fixedTunnel = Get-FixedTunnelConfig
  $fixedBarberUrl = ""
  if ($fixedTunnel) {
    $fixedBarberUrl = Get-BarberPortalUrl $fixedTunnel.PublicUrl
  }
  $usingFixedTunnel = [bool]($fixedTunnel -and $fixedBarberUrl)

  $startedServer = $null
  $listener = Get-PortListener
  if (-not $listener) {
    $startedServer = Start-ServerManaged $Python
    $listener = $startedServer.Listener
  } else {
    Add-ExistingServerIfSafe $listener | Out-Null
  }

  Show-Links $listener.OwningProcess
  Write-Step "Usando $($cloudflared.Version)"
  if ($usingFixedTunnel) {
    Write-Step "Creando acceso publico con link fijo..."
  } else {
    Write-Step "Creando puente HTTPS temporal para datos moviles..."
  }
  Write-Host ""
  if ($usingFixedTunnel) {
    Save-BarberLink $fixedBarberUrl "Este link fijo funciona con datos moviles mientras esta ventana, el servidor y el tunel fijo esten activos."
    Write-Host "LINK FIJO BARBEROS:"
    Write-Host $fixedBarberUrl
    Write-Host ""
    Write-Host "Tambien quedo guardado y copiado desde:"
    Write-Host $BarberLinkPath
    Write-Host ""
    if (-not $NoBrowser) {
      Start-Process $fixedBarberUrl
    }
    Write-Host "El link es el mismo siempre, pero solo funciona mientras esta ventana este abierta."
  } else {
    Write-Host "Esperando el puente temporal de Cloudflare..."
    Write-Host "Cuando aparezca, comparte con los barberos el link HTTPS terminado en /barberos."
    Write-Host "Este link cambia cada vez que reinicias el tunel."
  }
  Write-Host ""

  $logDir = Join-Path $AppRoot "tools\logs"
  New-Item -ItemType Directory -Force -Path $logDir | Out-Null
  $stdoutLog = Join-Path $logDir "cloudflared-out.log"
  $stderrLog = Join-Path $logDir "cloudflared-err.log"
  Remove-Item -LiteralPath $stdoutLog, $stderrLog -Force -ErrorAction SilentlyContinue

  if ($usingFixedTunnel) {
    $tunnelArgs = @("tunnel", "run", "--token", $fixedTunnel.Token)
  } else {
    $tunnelArgs = @("tunnel", "--url", "http://localhost:$Port")
  }

  $tunnel = Start-Process -FilePath $cloudflared.File `
    -ArgumentList $tunnelArgs `
    -NoNewWindow `
    -PassThru `
    -RedirectStandardOutput $stdoutLog `
    -RedirectStandardError $stderrLog
  Add-ManagedProcess $tunnel

  $printedUrl = [bool]$usingFixedTunnel
  try {
    while (-not $tunnel.HasExited) {
      Start-Sleep -Seconds 1
      $text = ""
      if (Test-Path $stdoutLog) {
        $text += (Get-Content -LiteralPath $stdoutLog -Raw -ErrorAction SilentlyContinue)
      }
      if (Test-Path $stderrLog) {
        $text += "`n" + (Get-Content -LiteralPath $stderrLog -Raw -ErrorAction SilentlyContinue)
      }

      if (-not $printedUrl -and $text -match "https://[a-zA-Z0-9.-]+\.trycloudflare\.com") {
        $publicUrl = $Matches[0]
        $barberUrl = Get-BarberPortalUrl $publicUrl
        Save-BarberLink $barberUrl "Este es el puente temporal para datos moviles. Funciona mientras esta ventana, el servidor y el tunel esten activos. Cambia cuando reinicias el programa."
        Write-Host ""
        Write-Host "========================================"
        Write-Host "PUENTE TEMPORAL BARBEROS:"
        Write-Host $barberUrl
        Write-Host ""
        Write-Host "Tambien quedo guardado y copiado desde:"
        Write-Host $BarberLinkPath
        Write-Host ""
        Write-Host "Admin sigue siendo local:"
        Write-Host "$AdminUrl"
        Write-Host "========================================"
        Write-Host ""
        $printedUrl = $true
        if (-not $NoBrowser) {
          Start-Process $barberUrl
        }
      }
    }

    Write-Host ""
    if ($usingFixedTunnel) {
      Write-Host "El tunel fijo se detuvo. Ultimos logs:"
    } elseif (-not $printedUrl) {
      Write-Host "cloudflared termino sin publicar un puente temporal. Ultimos logs:"
    } else {
      Write-Host "El puente temporal se detuvo. Ultimos logs:"
    }
    if (Test-Path $stderrLog) {
      Get-Content -LiteralPath $stderrLog -Tail 30
    }
  } finally {
    Stop-ManagedProcesses
  }
}

try {
  Set-Location $AppRoot

  if (-not (Test-Path "server.py")) {
    throw "No se encontro server.py en $AppRoot."
  }
  Build-AngularIfNeeded

  if (-not (Test-Path "frontend\dist\frontend\browser\index.html")) {
    throw "No se encontro el build Angular. Revisa frontend\ y vuelve a ejecutar el arrancador."
  }

  $python = Find-Python
  if (-not $python) {
    $python = Install-Python
  }
  if (-not $python) {
    throw "No se pudo instalar o encontrar Python automaticamente."
  }

  Write-Step "Usando $($python.Version)"
  Write-Step "Validando servidor..."
  Invoke-Python $python @("-m", "py_compile", "server.py")

  if ($Internet) {
    if ($CheckOnly) {
      $ngrokConfig = Get-NgrokConfig
      if ($ngrokConfig) {
        $ngrok = Find-Ngrok
        if (-not $ngrok) {
          $ngrok = Install-Ngrok
        }
        Write-Step "Listo para internet con $($ngrok.Version)"
        Write-Step "Link fijo ngrok: $(Get-BarberPortalUrl $ngrokConfig.PublicUrl)"
      } else {
        $cloudflared = Find-Cloudflared
        if (-not $cloudflared) {
          $cloudflared = Install-Cloudflared
        }
        Write-Step "Listo para internet con $($cloudflared.Version)"
        $fixedTunnel = Get-FixedTunnelConfig
        if ($fixedTunnel) {
          $barberUrl = Get-BarberPortalUrl $fixedTunnel.PublicUrl
          if ($barberUrl) {
            Write-Step "Link fijo Cloudflare configurado: $barberUrl"
          } else {
            Write-Step "Tunel fijo configurado, pero falta guardar el dominio publico en $FixedTunnelPublicUrlPath"
            Write-Step "Mientras tanto se usara puente temporal trycloudflare."
          }
        } else {
          Write-Step "Sin ngrok configurado; se usara puente temporal trycloudflare."
        }
      }
      exit 0
    }

    Start-InternetTunnel $python
    exit 0
  }

  $listener = Get-PortListener
  if ($listener) {
    Show-Links $listener.OwningProcess
    if ($CheckOnly) {
      Write-Step "Validacion lista. Ya hay un proceso escuchando en el puerto $Port."
      exit 0
    }

    $managedExistingServer = Add-ExistingServerIfSafe $listener
    if ($managedExistingServer) {
      Write-Step "El servidor ya estaba corriendo. Esta ventana lo apagara al cerrarse."
    } else {
      Write-Step "El puerto $Port ya esta ocupado por otro proceso; no se apagara automaticamente."
    }
    Open-Admin
    if (-not $NoPause) {
      Read-Host "Presiona Enter para apagar esta demo"
    }
    exit 0
  }

  if ($CheckOnly) {
    Write-Step "Validacion lista. No hay servidor escuchando en el puerto $Port."
    exit 0
  }

  $server = Start-ServerManaged $python
  Show-Links $server.Listener.OwningProcess
  Write-Step "Servidor activo. Cierra esta ventana o usa Ctrl+C para detenerlo todo."
  Open-Admin

  Wait-Process -Id $server.Process.Id
  $server.Process.Refresh()
  if ($server.Process.ExitCode -ne 0) {
    throw "El servidor termino con codigo $($server.Process.ExitCode)."
  }
} catch {
  Write-Host ""
  Write-Host "No se pudo iniciar la demo:" -ForegroundColor Red
  Write-Host $_.Exception.Message -ForegroundColor Red
  Write-Host ""
  if (-not $NoPause) {
    Read-Host "Presiona Enter para cerrar esta ventana"
  }
  exit 1
} finally {
  Stop-ManagedProcesses
}
