param(
  [Parameter(Mandatory = $true)][string]$ModelKey,
  [Parameter(Mandatory = $true)][string]$Backend,
  [int]$Context = 0,
  [switch]$Vision,
  [switch]$Mtp
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$configDirectory = Join-Path $root 'config'

$catalog = Get-Content -Raw -LiteralPath (Join-Path $configDirectory 'models.json') | ConvertFrom-Json
$backends = Get-Content -Raw -LiteralPath (Join-Path $configDirectory 'backends.json') | ConvertFrom-Json
$serverConfig = Get-Content -Raw -LiteralPath (Join-Path $configDirectory 'server.json') | ConvertFrom-Json

# Keys starting with '_' are documentation inside the catalog, not models.
$modelNames = @($catalog.PSObject.Properties.Name | Where-Object { -not $_.StartsWith('_') })
if ($modelNames -notcontains $ModelKey) {
  throw "Unknown model: $ModelKey. Available: $($modelNames -join ', ')"
}
if (@($backends.PSObject.Properties.Name) -notcontains $Backend) {
  throw "Unknown backend: $Backend. Available: $(@($backends.PSObject.Properties.Name) -join ', ')"
}

$model = $catalog.$ModelKey
$selectedBackend = $backends.$Backend
if ($Context -le 0) { $Context = $serverConfig.contextOptions[0] }
if ($Context -gt $model.geometry.maxContext) {
  throw "Context $Context exceeds the model maximum ($($model.geometry.maxContext))."
}
if ($Mtp -and -not $model.mtp) {
  throw "$($model.name) ships no MTP layers: speculative decoding cannot be enabled."
}

$server = Join-Path (Join-Path $root 'tools') (Join-Path $selectedBackend.folder 'llama-server.exe')
$modelPath = Join-Path (Join-Path $root 'models') $model.modelFile
$required = @($server, $modelPath)
$mmprojPath = Join-Path (Join-Path $root 'models') $model.mmprojFile
if ($Vision) { $required += $mmprojPath }
# Gemma 4 ships MTP as a separate draft model; Qwen embeds it in the main file.
$mtpPath = $null
if ($Mtp -and $model.mtp.mode -eq 'draft-model') {
  $mtpPath = Join-Path (Join-Path $root 'models') $model.mtp.file
  $required += $mtpPath
}
foreach ($path in $required) {
  if (-not (Test-Path -LiteralPath $path)) { throw "Not found: $path" }
}

Write-Host ''
Write-Host "  Model    : $($model.name)  [$($model.alias)]" -ForegroundColor Cyan
Write-Host "  Backend  : $($selectedBackend.name)" -ForegroundColor Cyan
Write-Host "  Context  : $($Context / 1024)K tokens" -ForegroundColor Cyan
Write-Host "  Vision   : $(if ($Vision) { 'on (mmproj F16)' } else { 'off' })" -ForegroundColor Cyan
Write-Host "  MTP      : $(if ($Mtp) { if ($mtpPath) { "on (draft model: $($model.mtp.file))" } else { 'on (embedded draft layers)' } } else { 'off' })" -ForegroundColor Cyan
Write-Host "  API      : http://$($serverConfig.host):$($serverConfig.port)/v1" -ForegroundColor Cyan
Write-Host ''

# Anything reported on screen is set by an explicit flag. Inheriting a default
# that can change between llama.cpp releases is not a guarantee.
$arguments = @(
  '--model', $modelPath
  '--alias', $model.alias
  '--ctx-size', $Context
  '--parallel', 1
  '--gpu-layers', $selectedBackend.gpuLayers
  '--spec-type', $(if ($Mtp) { 'draft-mtp' } else { 'none' })
  '--flash-attn', 'on'
  '--cache-type-k', $serverConfig.cacheType
  '--cache-type-v', $serverConfig.cacheType
  '--jinja'
  '--reasoning-preserve'
  '--cache-prompt'
  '--temp', 0.6
  '--top-p', 0.95
  '--top-k', 20
  '--min-p', 0.02
  '--host', $serverConfig.host
  '--port', $serverConfig.port
)
if ($Vision) {
  $arguments += @('--mmproj', $mmprojPath)
  # Raising the encoder's minimum resolution is model specific: Qwen's encoder
  # wants it, Gemma's refuses to load because the floor lands above its own
  # image_max_pixels. Only send it when the catalog asks for it.
  if ($model.imageMinTokens) { $arguments += @('--image-min-tokens', $model.imageMinTokens) }
}
if ($mtpPath) { $arguments += @('--spec-draft-model', $mtpPath) }

& $server @arguments
