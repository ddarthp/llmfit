param(
  # By default only what is installed gets verified, because the launcher
  # downloads on demand: a single backend with a single model is a valid
  # install. -Full requires the WHOLE catalog (useful before copying to a
  # USB stick).
  [switch]$Full
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$configDirectory = Join-Path $root 'config'
$models = Get-Content -Raw -LiteralPath (Join-Path $configDirectory 'models.json') | ConvertFrom-Json
$backends = Get-Content -Raw -LiteralPath (Join-Path $configDirectory 'backends.json') | ConvertFrom-Json
$runtimes = Get-Content -Raw -LiteralPath (Join-Path $configDirectory 'runtimes.json') | ConvertFrom-Json

$verified = @()
$skipped = @()
$problems = @()

function Test-Hash {
  param([string]$Path, [string]$Sha256, [string]$Label)
  $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
  if ($actual -ne $Sha256) {
    $script:problems += "$Label is corrupt or incomplete: $Path"
    Write-Host "FAIL: $Label" -ForegroundColor Red
    return $false
  }
  $script:verified += $Label
  Write-Host "OK: $Label" -ForegroundColor Green
  return $true
}

function Test-Tree {
  param([string]$Path, [int]$Files, [long]$Bytes, [string]$Label)
  $items = @(Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue)
  $actualFiles = $items.Count
  $actualBytes = ($items | Measure-Object -Property Length -Sum).Sum
  if ($null -eq $actualBytes) { $actualBytes = 0 }
  if ($actualFiles -ne $Files -or $actualBytes -ne $Bytes) {
    $script:problems += "$Label incomplete: expected $Files files / $Bytes bytes, found $actualFiles / $actualBytes"
    Write-Host "FAIL: $Label ($actualFiles/$Files files)" -ForegroundColor Red
    return $false
  }
  $script:verified += $Label
  Write-Host "OK: $Label ($actualFiles files)" -ForegroundColor Green
  return $true
}

Write-Host ''
$mode = if ($Full) { 'full (requires the whole catalog)' } else { 'installed (only what is present)' }
Write-Host "Verifying the package. Mode: $mode" -ForegroundColor Cyan
Write-Host 'Hashing the models takes several minutes. Do not close this window.' -ForegroundColor DarkGray
Write-Host ''

Write-Host '--- Models ---' -ForegroundColor Cyan
foreach ($property in $models.PSObject.Properties) {
  $model = $property.Value
  $files = @(
    @{ Path = Join-Path (Join-Path $root 'models') $model.modelFile; Sha256 = $model.modelSha256; Label = $model.modelFile },
    @{ Path = Join-Path (Join-Path $root 'models') $model.mmprojFile; Sha256 = $model.mmprojSha256; Label = $model.mmprojFile }
  )
  foreach ($file in $files) {
    if (Test-Path -LiteralPath $file.Path) {
      Test-Hash -Path $file.Path -Sha256 $file.Sha256 -Label $file.Label | Out-Null
    } elseif ($Full) {
      $problems += "Missing model file: $($file.Path)"
      Write-Host "MISSING: $($file.Label)" -ForegroundColor Red
    } else {
      $skipped += "$($file.Label) (not installed)"
      Write-Host "SKIPPED: $($file.Label) - not installed" -ForegroundColor DarkGray
    }
  }
}

Write-Host ''
Write-Host '--- llama.cpp backends ---' -ForegroundColor Cyan
foreach ($property in $backends.PSObject.Properties) {
  $backend = $property.Value
  $folder = Join-Path (Join-Path $root 'tools') $backend.folder
  $installed = Test-Path -LiteralPath (Join-Path $folder 'llama-server.exe')

  if (-not $installed) {
    if ($Full) {
      $problems += "Missing extracted backend: $folder"
      Write-Host "MISSING: $($property.Name) - backend not extracted" -ForegroundColor Red
    } else {
      $skipped += "$($property.Name) (backend not installed)"
      Write-Host "SKIPPED: $($property.Name) - not installed" -ForegroundColor DarkGray
    }
    continue
  }

  Test-Tree -Path $folder -Files $backend.tree.files -Bytes $backend.tree.bytes -Label "backend $($property.Name)" | Out-Null
  foreach ($archive in $backend.archives) {
    $archivePath = Join-Path (Join-Path $root 'downloads') $archive.file
    if (Test-Path -LiteralPath $archivePath) {
      Test-Hash -Path $archivePath -Sha256 $archive.sha256 -Label $archive.file | Out-Null
    } else {
      $skipped += "$($archive.file) (archive already deleted; the extracted backend was verified)"
      Write-Host "SKIPPED: $($archive.file) - archive not kept" -ForegroundColor DarkGray
    }
  }
}

Write-Host ''
Write-Host '--- Runtimes (Node and Pi) ---' -ForegroundColor Cyan
Write-Host 'Thousands of small files: the part a USB copy is most likely to truncate.' -ForegroundColor DarkGray
foreach ($property in $runtimes.PSObject.Properties) {
  $runtime = $property.Value
  $folder = Join-Path (Join-Path $root 'tools') $runtime.folder
  $entrypoint = Join-Path $folder $runtime.entrypoint

  if (-not (Test-Path -LiteralPath $folder)) {
    if ($runtime.required -or $Full) {
      $problems += "Missing runtime: $folder"
      Write-Host "MISSING: $($runtime.name)" -ForegroundColor Red
    } else {
      $skipped += "$($runtime.name) (optional, not installed)"
      Write-Host "SKIPPED: $($runtime.name) - optional" -ForegroundColor DarkGray
    }
    continue
  }
  if (-not (Test-Path -LiteralPath $entrypoint)) {
    $problems += "Missing entrypoint for $($runtime.name): $entrypoint"
    Write-Host "FAIL: $($runtime.name) - entrypoint missing" -ForegroundColor Red
    continue
  }
  Test-Tree -Path $folder -Files $runtime.tree.files -Bytes $runtime.tree.bytes -Label $runtime.name | Out-Null
}

Write-Host ''
Write-Host '=========================================' -ForegroundColor Cyan
Write-Host "Verified: $($verified.Count)" -ForegroundColor Green
if ($skipped.Count) {
  Write-Host "Skipped:  $($skipped.Count)" -ForegroundColor DarkGray
  foreach ($item in $skipped) { Write-Host "  - $item" -ForegroundColor DarkGray }
}

if ($problems.Count) {
  Write-Host ''
  Write-Host "PACKAGE HAS PROBLEMS ($($problems.Count))" -ForegroundColor Red
  foreach ($problem in $problems) { Write-Host "  - $problem" -ForegroundColor Red }
  Write-Host ''
  Write-Host 'Corrupt models and backends repair themselves: delete the file and run llmfit.' -ForegroundColor Yellow
  Write-Host 'Runtimes (node/pi) have to be copied again from the source.' -ForegroundColor Yellow
  exit 1
}

Write-Host ''
if ($Full) {
  Write-Host 'PACKAGE COMPLETE AND VERIFIED' -ForegroundColor Green
} else {
  Write-Host 'EVERYTHING INSTALLED IS VERIFIED' -ForegroundColor Green
  Write-Host 'To require the full catalog before copying to a USB stick: verify.ps1 -Full' -ForegroundColor DarkGray
}
