param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("Upload", "List", "Download")]
  [string]$Action,
  [string]$Month = "",
  [string]$Date = "",
  [string]$AppRoot = ""
)

$ErrorActionPreference = "Stop"
$OutputEncoding = [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

if (-not $AppRoot) {
  $AppRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
} else {
  $AppRoot = (Resolve-Path $AppRoot).Path
}

$Branch = "historial-datos"
$Remote = "origin"
$RemoteRef = "refs/remotes/$Remote/$Branch"
$ArchiveDirectory = Join-Path $AppRoot "data\history-archives"
$StatusPath = Join-Path $AppRoot "data\history-backup-status.json"
$UploadIndexPath = Join-Path $AppRoot "data\history-upload-index.json"
$InstallationIdPath = Join-Path $AppRoot "data\installation-id.txt"
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
  throw "Git no esta instalado."
}
$env:GIT_TERMINAL_PROMPT = "0"
$env:GCM_INTERACTIVE = "Never"
if (-not (Test-Path -LiteralPath (Join-Path $AppRoot ".git"))) {
  throw "La instalacion no conserva la carpeta .git."
}
if ($Month -and $Month -notmatch "^\d{4}-\d{2}$") {
  throw "El mes debe tener el formato AAAA-MM."
}
if ($Date -and $Date -notmatch "^\d{4}-\d{2}-\d{2}$") {
  throw "La fecha debe tener el formato AAAA-MM-DD."
}

function Get-InstallationId {
  if (Test-Path -LiteralPath $InstallationIdPath) {
    $saved = (Get-Content -LiteralPath $InstallationIdPath -Raw).Trim().ToLowerInvariant()
    if ($saved -match "^pc-[a-f0-9]{12}$") {
      return $saved
    }
  }
  $parent = Split-Path -Parent $InstallationIdPath
  New-Item -ItemType Directory -Path $parent -Force | Out-Null
  $created = "pc-" + [guid]::NewGuid().ToString("N").Substring(0, 12)
  Set-Content -LiteralPath $InstallationIdPath -Value $created -Encoding ASCII
  return $created
}

$InstallationId = Get-InstallationId

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
  return [pscustomobject]@{ ExitCode = $exitCode; Text = $text; Lines = $lines }
}

function Set-BackupStatus($State, $Message) {
  $parent = Split-Path -Parent $StatusPath
  New-Item -ItemType Directory -Path $parent -Force | Out-Null
  $temporaryStatus = "$StatusPath.tmp"
  [pscustomobject]@{
    state = $State
    month = $(if ($Month) { $Month } else { $Date.Substring(0, 7) })
    date = $Date
    message = $Message
    at = (Get-Date).ToString("o")
  } | ConvertTo-Json | Set-Content -LiteralPath $temporaryStatus -Encoding UTF8
  Move-Item -LiteralPath $temporaryStatus -Destination $StatusPath -Force
}

function Set-UploadedDate($Commit) {
  $uploaded = @{}
  if (Test-Path -LiteralPath $UploadIndexPath) {
    try {
      $existing = Get-Content -LiteralPath $UploadIndexPath -Raw | ConvertFrom-Json
      foreach ($property in $existing.PSObject.Properties) {
        $uploaded[$property.Name] = $property.Value
      }
    } catch {
      $uploaded = @{}
    }
  }
  $uploaded[$Date] = [pscustomobject]@{
    commit = $Commit
    uploaded_at = (Get-Date).ToString("o")
  }
  $uploaded | ConvertTo-Json | Set-Content -LiteralPath $UploadIndexPath -Encoding UTF8
}

function Enable-PartialHistoryFetch {
  Invoke-Git @("config", "remote.$Remote.promisor", "true") | Out-Null
  Invoke-Git @("config", "remote.$Remote.partialclonefilter", "blob:none") | Out-Null
}

function Fetch-HistoryBranch {
  Enable-PartialHistoryFetch
  $result = Invoke-Git @(
    "fetch", "--quiet", "--filter=blob:none", "--no-tags", $Remote,
    "+refs/heads/$Branch`:$RemoteRef"
  ) -AllowFailure
  if ($result.ExitCode -eq 0) {
    return $true
  }
  if ($result.Text -match "couldn't find remote ref|no se pudo encontrar la referencia remota") {
    return $false
  }
  throw $result.Text
}

function Export-GitBlob($ObjectSpec, $Destination) {
  $process = New-Object System.Diagnostics.Process
  $fileStream = $null
  try {
    $process.StartInfo.FileName = $GitExe
    $process.StartInfo.WorkingDirectory = $AppRoot
    $process.StartInfo.Arguments = "show `"$ObjectSpec`""
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    if (-not $process.Start()) {
      throw "No se pudo iniciar Git para descargar el mes."
    }
    $fileStream = [System.IO.File]::Open(
      $Destination,
      [System.IO.FileMode]::Create,
      [System.IO.FileAccess]::Write,
      [System.IO.FileShare]::None
    )
    $process.StandardOutput.BaseStream.CopyTo($fileStream)
    $fileStream.Close()
    $fileStream = $null
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) {
      throw $process.StandardError.ReadToEnd().Trim()
    }
  } finally {
    if ($fileStream) { $fileStream.Dispose() }
    $process.Dispose()
  }
}

function Get-FriendlyGitMessage($Message) {
  $text = "$Message"
  if (
    $text -match "Authentication failed|could not read Username|terminal prompts disabled|" +
      "interactiv.*disabled|GCM_INTERACTIVE|permission denied|write access.*not granted|" +
      "HTTP 403|returned error: 403|repository not found"
  ) {
    return (
      "Este PC todavia no esta autorizado para guardar respaldos en GitHub. " +
      "Ejecuta 'Configurar GitHub.cmd' una vez e inicia sesion con una cuenta que tenga " +
      "permiso de escritura en el repositorio."
    )
  }
  return $text
}

try {
  if ($Action -eq "List") {
    if (-not (Fetch-HistoryBranch)) {
      [pscustomobject]@{ months = @() } | ConvertTo-Json -Compress
      exit 0
    }
    $tree = Invoke-Git @("ls-tree", "-r", "--name-only", $RemoteRef, "meses")
    $months = @(
      $tree.Lines |
        ForEach-Object {
          if ("$_" -match "^meses/(\d{4}-\d{2})/\d{4}-\d{2}-\d{2}(?:-pc-[a-f0-9]{12})?\.zip$") { $Matches[1] }
        } |
        Where-Object { $_ } |
        Sort-Object -Descending -Unique
    )
    [pscustomobject]@{ months = $months } | ConvertTo-Json -Compress
    exit 0
  }

  New-Item -ItemType Directory -Path $ArchiveDirectory -Force | Out-Null

  if ($Action -eq "Download") {
    if (-not $Month) {
      throw "Debes indicar el mes."
    }
    if (-not (Fetch-HistoryBranch)) {
      throw "Todavia no hay respaldos remotos."
    }
    $tree = Invoke-Git @("ls-tree", "-r", "--name-only", $RemoteRef, "meses/$Month")
    $remoteFiles = @(
      $tree.Lines |
        Where-Object {
          "$_" -match "^meses/$Month/\d{4}-\d{2}-\d{2}(?:-pc-[a-f0-9]{12})?\.zip$"
        }
    )
    if (-not $remoteFiles.Count) {
      throw "No existe un respaldo remoto para $Month."
    }
    foreach ($remoteFile in $remoteFiles) {
      $filename = Split-Path -Leaf $remoteFile
      $archivePath = Join-Path $ArchiveDirectory $filename
      $temporaryPath = Join-Path $ArchiveDirectory "$filename.download"
      Export-GitBlob "$RemoteRef`:$remoteFile" $temporaryPath
      Move-Item -LiteralPath $temporaryPath -Destination $archivePath -Force
    }
    [pscustomobject]@{ ok = $true; month = $Month; files = $remoteFiles.Count } |
      ConvertTo-Json -Compress
    exit 0
  }

  if (-not $Date) {
    throw "Debes indicar la fecha que se va a respaldar."
  }
  $Month = $Date.Substring(0, 7)
  $archivePath = Join-Path $ArchiveDirectory "$Date.zip"
  if (-not (Test-Path -LiteralPath $archivePath)) {
    throw "No existe el archivo local del dia $Date."
  }

  Set-BackupStatus "uploading" "Subiendo el historial a GitHub."
  $blobResult = Invoke-Git @("hash-object", "-w", $archivePath)
  $blob = @($blobResult.Lines | Where-Object { "$_" -match "^[0-9a-f]{40,64}$" })[-1]
  if (-not $blob) {
    throw "Git no devolvio el identificador del archivo de respaldo."
  }

  $temporaryIndex = Join-Path $env:TEMP ("capitan-gold-index-" + [guid]::NewGuid().ToString("N"))
  $previousIndex = $env:GIT_INDEX_FILE
  $commit = ""
  $uploaded = $false
  try {
    $env:GIT_INDEX_FILE = $temporaryIndex
    $env:GIT_AUTHOR_NAME = "Capitan Gold"
    $env:GIT_AUTHOR_EMAIL = "respaldos@capitangold.local"
    $env:GIT_COMMITTER_NAME = "Capitan Gold"
    $env:GIT_COMMITTER_EMAIL = "respaldos@capitangold.local"

    for ($attempt = 1; $attempt -le 4; $attempt++) {
      $hasRemoteBranch = Fetch-HistoryBranch
      if ($hasRemoteBranch) {
        Invoke-Git @("read-tree", $RemoteRef) | Out-Null
      } else {
        Invoke-Git @("read-tree", "--empty") | Out-Null
      }
      Invoke-Git @(
        "update-index", "--add", "--cacheinfo",
        "100644,$blob,meses/$Month/$Date-$InstallationId.zip"
      ) | Out-Null
      $tree = (Invoke-Git @("write-tree")).Text

      $commitArguments = @(
        "commit-tree", $tree, "-m", "Respaldo automatico $Date ($InstallationId)"
      )
      if ($hasRemoteBranch) {
        $parent = (Invoke-Git @("rev-parse", $RemoteRef)).Text
        $commitArguments += @("-p", $parent)
      }
      $commit = (Invoke-Git $commitArguments).Text
      $pushResult = Invoke-Git @(
        "push", "--quiet", $Remote, "$commit`:refs/heads/$Branch"
      ) -AllowFailure
      if ($pushResult.ExitCode -eq 0) {
        $uploaded = $true
        break
      }
      if (
        $attempt -lt 4 -and
        $pushResult.Text -match "non-fast-forward|fetch first|stale info|rejected"
      ) {
        Start-Sleep -Milliseconds (250 * $attempt)
        continue
      }
      throw $pushResult.Text
    }
  } finally {
    $env:GIT_INDEX_FILE = $previousIndex
    Remove-Item -LiteralPath $temporaryIndex -Force -ErrorAction SilentlyContinue
  }
  if (-not $uploaded) {
    throw "GitHub rechazo el respaldo despues de varios intentos."
  }

  Set-UploadedDate $commit
  Set-BackupStatus "success" "Historial $Date respaldado en GitHub desde $InstallationId."
  [pscustomobject]@{
    ok = $true
    month = $Month
    date = $Date
    installation = $InstallationId
  } | ConvertTo-Json -Compress
  exit 0
} catch {
  $friendlyMessage = Get-FriendlyGitMessage $_.Exception.Message
  if ($Action -eq "Upload") {
    Set-BackupStatus "error" $friendlyMessage
  }
  [Console]::Error.WriteLine($friendlyMessage)
  exit 1
}
