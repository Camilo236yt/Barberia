param(
  [string]$AppRoot = "",
  [string]$Remote = "origin",
  [string]$Branch = "main",
  [int]$FetchTimeoutSeconds = 25,
  [switch]$CheckOnly,
  [switch]$AcceptUpdate,
  [switch]$DeclineUpdate,
  [switch]$SkipFetch
)

$ErrorActionPreference = "Stop"
$OutputEncoding = [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

if (-not $AppRoot) {
  $AppRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
} else {
  $AppRoot = (Resolve-Path $AppRoot).Path
}

$RuntimePaths = @(
  "data",
  "LINK_ADMIN_ONLINE.txt",
  "tools/logs",
  "tools/ngrok/authtoken.txt",
  "tools/ngrok/public-url.txt",
  "tools/cloudflare-worker/public-url.txt",
  "__pycache__"
)

$LocalDependencyPaths = @(
  "tools/python",
  "tools/ngrok/ngrok.exe"
)

$UpdateStateRoot = Join-Path $env:LOCALAPPDATA "CapitanGold\updates"
$appRootBytes = [System.Text.Encoding]::UTF8.GetBytes($AppRoot.ToLowerInvariant())
$appRootHash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($appRootBytes)
$appId = ([System.BitConverter]::ToString($appRootHash)).Replace("-", "").Substring(0, 16)
$PendingMarker = Join-Path $UpdateStateRoot "pending-update-$appId.json"
$script:GitExe = $null

function Write-Update($Message, $Color = "") {
  if ($Color) {
    Write-Host "[Actualizacion] $Message" -ForegroundColor $Color
  } else {
    Write-Host "[Actualizacion] $Message"
  }
}

function Invoke-Git($Arguments, [switch]$AllowFailure) {
  $previousErrorPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = "Continue"
    $lines = @(& $script:GitExe -C $AppRoot @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorPreference
  }
  if ($exitCode -ne 0 -and -not $AllowFailure) {
    $detail = ($lines | ForEach-Object { "$_" }) -join [Environment]::NewLine
    if (-not $detail) {
      $detail = "Git termino con el codigo $exitCode."
    }
    throw $detail
  }
  return [pscustomobject]@{
    ExitCode = $exitCode
    Lines = @($lines | ForEach-Object { "$_" })
    Text = (($lines | ForEach-Object { "$_" }) -join [Environment]::NewLine).Trim()
  }
}

function Test-RuntimePath($Path) {
  $normalized = $Path.Replace("\", "/").Trim('"')
  if ($normalized.Contains(" -> ")) {
    $normalized = ($normalized -split " -> ")[-1]
  }
  foreach ($runtimePath in @($RuntimePaths + $LocalDependencyPaths)) {
    $runtimeNormalized = $runtimePath.Replace("\", "/")
    if ($normalized -eq $runtimeNormalized -or $normalized.StartsWith("$runtimeNormalized/")) {
      return $true
    }
  }
  return $false
}

function Get-WorkingTreeChanges {
  $status = Invoke-Git @("status", "--porcelain=v1", "--untracked-files=all")
  $changes = @()
  foreach ($line in $status.Lines) {
    if ($line.Length -lt 4) {
      continue
    }
    $path = $line.Substring(3).Trim()
    $changes += [pscustomobject]@{
      Status = $line.Substring(0, 2)
      Path = $path
      Runtime = Test-RuntimePath $path
    }
  }
  return $changes
}

function Backup-RuntimeData {
  $stamp = (Get-Date -Format "yyyyMMdd-HHmmss") + "-$PID-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
  $backupRoot = Join-Path $UpdateStateRoot "backups\$appId\$stamp"
  New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null

  foreach ($relativePath in $RuntimePaths) {
    $source = Join-Path $AppRoot $relativePath
    if (-not (Test-Path -LiteralPath $source)) {
      continue
    }

    $item = Get-Item -LiteralPath $source
    if ($item.PSIsContainer) {
      $sourcePrefix = $item.FullName.TrimEnd([char[]]@("\", "/")) + [System.IO.Path]::DirectorySeparatorChar
      foreach ($file in Get-ChildItem -LiteralPath $item.FullName -File -Recurse -Force) {
        if (-not $file.FullName.StartsWith($sourcePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
          throw "El archivo local esta fuera de la carpeta protegida: $($file.FullName)"
        }
        $innerPath = $file.FullName.Substring($sourcePrefix.Length)
        $relativeFile = Join-Path $relativePath $innerPath
        $destination = Join-Path $backupRoot $relativeFile
        $destinationParent = Split-Path -Parent $destination
        New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
      }
    } else {
      $relativeFile = $relativePath
      $destination = Join-Path $backupRoot $relativeFile
      $destinationParent = Split-Path -Parent $destination
      New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
      Copy-Item -LiteralPath $item.FullName -Destination $destination -Force
    }
  }

  return $backupRoot
}

function Backup-ModifiedCode($Changes) {
  if (-not $Changes -or @($Changes).Count -eq 0) {
    return ""
  }
  $stamp = (Get-Date -Format "yyyyMMdd-HHmmss") + "-$PID-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
  $recoveryRoot = Join-Path $UpdateStateRoot "recovery\$appId\$stamp"
  New-Item -ItemType Directory -Path $recoveryRoot -Force | Out-Null
  $manifest = @()

  foreach ($change in $Changes) {
    $relativePath = $change.Path.Trim('"')
    if ($relativePath.Contains(" -> ")) {
      $relativePath = ($relativePath -split " -> ")[-1]
    }
    $normalizedPath = $relativePath.Replace("/", "\")
    if ([System.IO.Path]::IsPathRooted($normalizedPath) -or
        @($normalizedPath.Split("\") | Where-Object { $_ -eq ".." }).Count -gt 0) {
      throw "Git devolvio una ruta no valida para recuperacion: $relativePath"
    }
    $source = [System.IO.Path]::GetFullPath((Join-Path $AppRoot $normalizedPath))
    $destination = [System.IO.Path]::GetFullPath((Join-Path $recoveryRoot $normalizedPath))
    $manifest += [pscustomobject]@{ status = $change.Status; path = $relativePath }
    if (Test-Path -LiteralPath $source -PathType Leaf) {
      $parent = Split-Path -Parent $destination
      New-Item -ItemType Directory -Path $parent -Force | Out-Null
      Copy-Item -LiteralPath $source -Destination $destination -Force
    }
  }

  $manifest | ConvertTo-Json | Set-Content `
    -LiteralPath (Join-Path $recoveryRoot "archivos-modificados.json") `
    -Encoding UTF8
  return $recoveryRoot
}

function Set-LightweightSparseCheckout {
  Invoke-Git @("sparse-checkout", "init", "--no-cone") | Out-Null
  Invoke-Git @(
    "sparse-checkout", "set", "--no-cone",
    "/*",
    "!/data/",
    "!/tools/node/",
    "!/tools/python/",
    "!/tools/cloudflared/",
    "!/tools/cloudflare-worker/",
    "!/tools/backups/",
    "!/tools/logs/",
    "!/frontend/node_modules/"
  ) | Out-Null
}

function Restore-RuntimeData($BackupRoot) {
  if (-not $BackupRoot -or -not (Test-Path -LiteralPath $BackupRoot)) {
    return
  }

  $resolvedBackupRoot = (Get-Item -LiteralPath $BackupRoot).FullName
  $backupPrefix = $resolvedBackupRoot.TrimEnd([char[]]@("\", "/")) + [System.IO.Path]::DirectorySeparatorChar
  foreach ($file in Get-ChildItem -LiteralPath $resolvedBackupRoot -File -Recurse -Force) {
    if (-not $file.FullName.StartsWith($backupPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "El respaldo contiene una ruta no valida: $($file.FullName)"
    }
    $relativeFile = $file.FullName.Substring($backupPrefix.Length)
    $destination = Join-Path $AppRoot $relativeFile
    $destinationParent = Split-Path -Parent $destination
    New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
    Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
  }
}

function Recover-PendingUpdate {
  if (-not (Test-Path -LiteralPath $PendingMarker)) {
    return
  }
  try {
    $pending = Get-Content -LiteralPath $PendingMarker -Raw | ConvertFrom-Json
    if ($pending.AppRoot -eq $AppRoot -and (Test-Path -LiteralPath $pending.BackupRoot)) {
      Write-Update "Restaurando datos locales protegidos de una actualizacion interrumpida..." "Yellow"
      Restore-RuntimeData $pending.BackupRoot
    }
    Remove-Item -LiteralPath $PendingMarker -Force -ErrorAction SilentlyContinue
  } catch {
    Write-Update "No se pudo comprobar un respaldo pendiente: $($_.Exception.Message)" "Yellow"
  }
}

function Start-Fetch {
  if ($Remote -notmatch "^[A-Za-z0-9._/-]+$" -or $Branch -notmatch "^[A-Za-z0-9._/-]+$") {
    throw "El nombre del remoto o de la rama no es valido."
  }

  $process = New-Object System.Diagnostics.Process
  try {
    $env:GIT_TERMINAL_PROMPT = "0"
    $process.StartInfo.FileName = $script:GitExe
    $process.StartInfo.WorkingDirectory = $AppRoot
    $process.StartInfo.Arguments = "-c credential.interactive=never -c core.askPass= fetch --quiet --prune $Remote $Branch"
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    if (-not $process.Start()) {
      Write-Update "No se pudo iniciar la comprobacion de GitHub." "Yellow"
      return $false
    }

    if (-not $process.WaitForExit($FetchTimeoutSeconds * 1000)) {
      try { $process.Kill() } catch {}
      Write-Update "La comprobacion tardo demasiado. El programa iniciara sin actualizar." "Yellow"
      return $false
    }
    if ($process.ExitCode -ne 0) {
      $detail = $process.StandardError.ReadToEnd().Trim()
      Write-Update "No se pudo consultar GitHub. El programa iniciara normalmente." "Yellow"
      if ($detail) {
        Write-Host "  $detail"
      }
      return $false
    }
    return $true
  } finally {
    $process.Dispose()
  }
}

function Show-Question($Message) {
  if ($AcceptUpdate) {
    return $true
  }
  if ($DeclineUpdate -or $CheckOnly) {
    return $false
  }

  try {
    Add-Type -AssemblyName System.Windows.Forms
    $result = [System.Windows.Forms.MessageBox]::Show(
      $Message,
      "Actualizacion disponible - Capitan Gold",
      [System.Windows.Forms.MessageBoxButtons]::YesNo,
      [System.Windows.Forms.MessageBoxIcon]::Information,
      [System.Windows.Forms.MessageBoxDefaultButton]::Button2
    )
    return $result -eq [System.Windows.Forms.DialogResult]::Yes
  } catch {
    Write-Host ""
    Write-Host $Message
    $answer = Read-Host "Escribe SI para actualizar"
    return $answer.Trim().ToUpperInvariant() -eq "SI"
  }
}

function Show-Information($Message, $Title = "Capitan Gold") {
  try {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show(
      $Message,
      $Title,
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
  } catch {
    Write-Host $Message
  }
}

function Remove-CreatedStash($StashHash) {
  if (-not $StashHash) {
    return
  }
  $list = Invoke-Git @("stash", "list", "--format=%gd`t%H") -AllowFailure
  foreach ($line in $list.Lines) {
    $parts = $line -split "`t", 2
    if ($parts.Count -eq 2 -and $parts[1] -eq $StashHash) {
      Invoke-Git @("stash", "drop", "--quiet", $parts[0]) -AllowFailure | Out-Null
      return
    }
  }
}

try {
  Set-Location $AppRoot
  New-Item -ItemType Directory -Path $UpdateStateRoot -Force | Out-Null
  Recover-PendingUpdate

  if (-not (Test-Path -LiteralPath (Join-Path $AppRoot ".git"))) {
    Write-Update "Esta copia no contiene la informacion de Git; se omite la comprobacion." "Yellow"
    exit 0
  }

  $portableGit = Join-Path $env:LOCALAPPDATA "CapitanGold\Git\cmd\git.exe"
  $gitCommand = if (Test-Path -LiteralPath $portableGit) {
    [pscustomobject]@{ Source = $portableGit }
  } else {
    Get-Command git.exe -ErrorAction SilentlyContinue
  }
  if (-not $gitCommand) {
    $gitCommand = Get-Command git -ErrorAction SilentlyContinue
  }
  if (-not $gitCommand) {
    Write-Update "Git no esta instalado. El programa iniciara sin comprobar actualizaciones." "Yellow"
    exit 0
  }
  $script:GitExe = $gitCommand.Source

  if (-not $SkipFetch -and -not (Start-Fetch)) {
    exit 0
  }

  $remoteRef = "$Remote/$Branch"
  $localRevision = (Invoke-Git @("rev-parse", "HEAD")).Text
  $remoteResult = Invoke-Git @("rev-parse", "--verify", $remoteRef) -AllowFailure
  if ($remoteResult.ExitCode -ne 0) {
    Write-Update "No se encontro la rama $remoteRef. El programa iniciara sin actualizar." "Yellow"
    exit 0
  }
  $remoteRevision = $remoteResult.Text
  $changes = @(Get-WorkingTreeChanges)
  $codeChanges = @($changes | Where-Object { -not $_.Runtime })
  $needsRepair = $codeChanges.Count -gt 0

  if ($localRevision -eq $remoteRevision -and -not $needsRepair) {
    Write-Update "El programa ya esta actualizado."
    exit 0
  }

  $commitCount = (Invoke-Git @("rev-list", "--count", "$localRevision..$remoteRevision")).Text
  $notes = (Invoke-Git @(
    "log", "--reverse", "--date=short",
    "--format=- %ad - %s%n%b",
    "$localRevision..$remoteRevision"
  )).Text
  if (-not $notes) {
    $notes = if ($needsRepair) {
      "Reparacion de archivos modificados, faltantes o incompatibles."
    } else {
      "Sincronizacion completa con la version oficial."
    }
  }
  if ($notes.Length -gt 3500) {
    $notes = $notes.Substring(0, 3500) + "`n`n... y otros cambios."
  }

  $headline = if ($localRevision -eq $remoteRevision) {
    "La instalacion necesita una reparacion."
  } else {
    "Hay una nueva actualizacion disponible ($commitCount cambio(s))."
  }
  $message = @"
$headline

CAMBIOS Y REPARACIONES:

$notes

¿Quieres descargarla e instalarla ahora?

La contabilidad, imagenes y configuracion local se conservaran. Los archivos modificados del programa se guardaran en una carpeta de recuperacion antes de reemplazarlos.
"@

  Write-Update $headline "Cyan"
  Write-Host ""
  Write-Host $notes

  if (-not (Show-Question $message)) {
    Write-Update "Actualizacion pospuesta. El programa iniciara con la version actual."
    exit 0
  }

  $listener = Get-NetTCPConnection -LocalPort 8000 -State Listen -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if ($listener) {
    Show-Information `
      "No se puede actualizar mientras Barberia Control esta abierto.`n`nCierra la otra ventana del programa y vuelve a iniciar." `
      "Cierra Barberia Control"
    exit 0
  }

  $recoveryRoot = ""
  if ($codeChanges.Count -gt 0) {
    Write-Update "Guardando los archivos modificados antes de reparar..." "Yellow"
    $recoveryRoot = Backup-ModifiedCode $codeChanges
    Write-Update "Copia de recuperacion: $recoveryRoot"
  }

  Write-Update "Protegiendo la contabilidad y la configuracion local..."
  $backupRoot = Backup-RuntimeData
  [pscustomobject]@{
    AppRoot = $AppRoot
    BackupRoot = $backupRoot
    CreatedAt = (Get-Date).ToString("o")
  } | ConvertTo-Json | Set-Content -LiteralPath $PendingMarker -Encoding UTF8

  $updateSucceeded = $false
  try {
    Write-Update "Sincronizando y reparando la instalacion..."
    Invoke-Git @("reset", "--hard", $remoteRef) | Out-Null
    Set-LightweightSparseCheckout
    Invoke-Git @(
      "clean", "-fdx",
      "-e", "data/",
      "-e", "LINK_ADMIN_ONLINE.txt",
      "-e", "tools/logs/",
      "-e", "tools/python/",
      "-e", "tools/ngrok/ngrok.exe",
      "-e", "tools/ngrok/authtoken.txt",
      "-e", "tools/ngrok/public-url.txt",
      "-e", "tools/cloudflare-worker/public-url.txt"
    ) | Out-Null
    foreach ($requiredPath in @(
      "server.py",
      "tools\start-barberia.ps1",
      "tools\update-barberia.ps1",
      "frontend\dist\frontend\browser\index.html"
    )) {
      if (-not (Test-Path -LiteralPath (Join-Path $AppRoot $requiredPath))) {
        throw "La recuperacion no encontro el archivo requerido: $requiredPath"
      }
    }
    $updateSucceeded = $true
  } finally {
    Restore-RuntimeData $backupRoot
    Remove-Item -LiteralPath $PendingMarker -Force -ErrorAction SilentlyContinue
  }

  if ($updateSucceeded) {
    Write-Update "Actualizacion instalada correctamente." "Green"
    if (-not $AcceptUpdate) {
      $recoveryMessage = if ($recoveryRoot) {
        "`n`nLos archivos locales anteriores quedaron en:`n$recoveryRoot"
      } else {
        ""
      }
      Show-Information `
        "La actualizacion y reparacion terminaron correctamente.`n`nBarberia Control continuara iniciando.$recoveryMessage" `
        "Actualizacion completada"
    }
  }
  exit 0
} catch {
  Write-Update "No se pudo completar la actualizacion. El programa iniciara con la version disponible." "Yellow"
  Write-Host "  $($_.Exception.Message)"
  if ($_.InvocationInfo.PositionMessage) {
    Write-Host "  $($_.InvocationInfo.PositionMessage.Trim())"
  }
  exit 0
}
