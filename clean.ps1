param(
  # Also delete the log and PID files a previous server run may have left behind.
  [switch]$IncludeLogs,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

# The llama.cpp archives are needed only once: after extraction the backend
# lives in tools\. They can always be downloaded again, because the catalog
# stores the URL and SHA-256 of every one of them.
$backends = Get-Content -Raw -LiteralPath (Join-Path $root 'config\backends.json') | ConvertFrom-Json
$targets = @()
foreach ($property in $backends.PSObject.Properties) {
  $backend = $property.Value
  $folder = Join-Path (Join-Path $root 'tools') $backend.folder
  if (-not (Test-Path -LiteralPath (Join-Path $folder 'llama-server.exe'))) { continue }
  foreach ($archive in $backend.archives) {
    $path = Join-Path (Join-Path $root 'downloads') $archive.file
    if (Test-Path -LiteralPath $path) {
      $targets += [pscustomobject]@{ Path = $path; Reason = "backend '$($property.Name)' already extracted" }
    }
  }
}

# Leftover extraction staging directories under tools\.
foreach ($leftover in @(Get-ChildItem -LiteralPath (Join-Path $root 'tools') -Directory -Filter '*-extract' -ErrorAction SilentlyContinue)) {
  $targets += [pscustomobject]@{ Path = $leftover.FullName; Reason = 'leftover extraction directory' }
}

if ($IncludeLogs) {
  foreach ($name in @('llama-server.pid', 'llama-server.log', 'llama-server.err.log')) {
    $path = Join-Path $root $name
    if (Test-Path -LiteralPath $path) {
      $targets += [pscustomobject]@{ Path = $path; Reason = 'runtime leftover' }
    }
  }
}

function Get-SizeBytes {
  param([string]$Path)
  $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
  if ($null -eq $item) { return 0 }
  if (-not $item.PSIsContainer) { return $item.Length }
  $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
  if ($null -eq $sum) { return 0 }
  return $sum
}

Write-Host ''
Write-Host 'Reclaim disk space' -ForegroundColor Cyan
Write-Host '==================' -ForegroundColor Cyan

if (-not $targets.Count) {
  Write-Host 'Nothing to clean.' -ForegroundColor Green
  exit 0
}

$total = [long]0
foreach ($target in $targets) {
  $size = Get-SizeBytes -Path $target.Path
  $total += $size
  Write-Host ("  {0,8:N1} MB  {1}" -f ($size / 1MB), (Split-Path -Leaf $target.Path))
  Write-Host ("             {0}" -f $target.Reason) -ForegroundColor DarkGray
}
Write-Host ''
Write-Host ("This frees {0:N2} GB." -f ($total / 1GB)) -ForegroundColor Yellow
Write-Host 'Models and extracted backends are left untouched.' -ForegroundColor DarkGray
Write-Host 'If an archive is needed later, the launcher downloads and verifies it again.' -ForegroundColor DarkGray

if (-not $Force) {
  Write-Host ''
  $answer = Read-Host 'Delete? [y/N]'
  if ($answer -notmatch '^[yYsS]') {
    Write-Host 'Cancelled. Nothing was deleted.' -ForegroundColor Yellow
    exit 0
  }
}

Write-Host ''
foreach ($target in $targets) {
  Remove-Item -LiteralPath $target.Path -Recurse -Force
  Write-Host "Deleted: $(Split-Path -Leaf $target.Path)" -ForegroundColor Green
}
Write-Host ''
Write-Host ("Done. Freed {0:N2} GB." -f ($total / 1GB)) -ForegroundColor Green
