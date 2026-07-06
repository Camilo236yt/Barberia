param(
  [string]$DataSourceRoot = "",
  [string]$PackagePath = ""
)

$ErrorActionPreference = "Stop"
$AppRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$CloudRoot = Join-Path $AppRoot "infinityfree"
$Htdocs = Join-Path $CloudRoot "htdocs"
$BrowserBuild = Join-Path $AppRoot "frontend\dist\frontend\browser"
$PortableNode = Join-Path $AppRoot "tools\node\node-v24.16.0-win-x64"
$Npm = Join-Path $PortableNode "npm.cmd"
$Python = Join-Path $AppRoot "tools\python\python.exe"

if (-not $DataSourceRoot) {
  $installed = Join-Path $env:LOCALAPPDATA "CapitanGold\Barberia"
  $DataSourceRoot = if (Test-Path -LiteralPath (Join-Path $installed "data\db.json")) {
    $installed
  } else {
    $AppRoot
  }
}
$DataSourceRoot = (Resolve-Path $DataSourceRoot).Path

if (-not (Test-Path -LiteralPath $Npm)) {
  throw "No se encontró Node portátil."
}
if (-not (Test-Path -LiteralPath $Python)) {
  throw "No se encontró Python portátil."
}

$env:Path = "$PortableNode;$env:Path"
& $Npm --prefix (Join-Path $AppRoot "frontend") run build
if ($LASTEXITCODE -ne 0) {
  throw "Angular no pudo compilar el paquete cloud."
}

New-Item -ItemType Directory -Path $Htdocs -Force | Out-Null
Copy-Item -Path (Join-Path $BrowserBuild "*") -Destination $Htdocs -Recurse -Force
Copy-Item -LiteralPath (Join-Path $CloudRoot "cloud-config.cloud.js") `
  -Destination (Join-Path $Htdocs "cloud-config.js") `
  -Force

$migrationPath = Join-Path $Htdocs "api\migration-data.json"
$uploadsPath = Join-Path $Htdocs "uploads"
$reportPath = Join-Path $CloudRoot "migration-report.json"
& $Python (Join-Path $AppRoot "tools\export-infinityfree-data.py") `
  --app-root $DataSourceRoot `
  --output $migrationPath `
  --uploads-output $uploadsPath `
  --report $reportPath
if ($LASTEXITCODE -ne 0) {
  throw "El exportador encontró comprobantes faltantes. Revisa migration-report.json."
}

if (-not $PackagePath) {
  $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $PackagePath = Join-Path (Split-Path -Parent $AppRoot) "CapitanGold-InfinityFree-$stamp.zip"
}
$PackagePath = [System.IO.Path]::GetFullPath($PackagePath)
if (Test-Path -LiteralPath $PackagePath) {
  throw "El paquete ya existe: $PackagePath"
}

& tar.exe -a -cf $PackagePath `
  --exclude="htdocs/api/config.php" `
  -C $CloudRoot `
  "README-SUBIDA.md" `
  "CONFIGURAR-GITHUB.md" `
  "schema.sql" `
  "htdocs"
if ($LASTEXITCODE -ne 0) {
  throw "No se pudo comprimir el paquete InfinityFree."
}

$hash = (Get-FileHash -LiteralPath $PackagePath -Algorithm SHA256).Hash
Write-Host "Paquete listo: $PackagePath"
Write-Host "SHA256: $hash"
