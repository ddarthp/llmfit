param(
  [Parameter(Mandatory = $true)][string]$ModelKey,
  [Parameter(Mandatory = $true)][string]$Backend,
  [int]$Context = 0,
  [string]$Device = '',
  [string]$CacheType = '',
  [switch]$Vision,
  [switch]$Mtp
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$configDirectory = Join-Path $root 'config'

# Windows PowerShell 5.1 defines neither $IsWindows nor $IsMacOS, and only ever
# runs on Windows, so their absence answers the question. See llmfit.ps1.
$onWindows = if ($null -ne $IsWindows) { [bool]$IsWindows } else { $true }
$onMacOS = if ($null -ne $IsMacOS) { [bool]$IsMacOS } else { $false }
$platform = if ($onMacOS) { 'macos' } else { 'windows' }
$serverExe = if ($onWindows) { 'llama-server.exe' } else { 'llama-server' }

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
# The launcher never offers MTP on a backend whose speculativeDecoding is false,
# so only a hand-written command reaches this. It has to stop here: measured on
# b10566, Gemma 4's draft model on Vulkan does not run slowly, it aborts the
# process inside ggml-backend.cpp with 'pre-allocated tensor (cache_k_l22) in a
# buffer (Vulkan0) that cannot run the operation'. A thrown message beats a
# stack trace from a crash the catalog already knew was coming.
if ($Mtp -and -not $selectedBackend.speculativeDecoding) {
  throw "Speculative decoding is not available on the $Backend backend. config/backends.json sets speculativeDecoding false there, and the comment beside it says why."
}

$server = Join-Path (Join-Path $root 'tools') (Join-Path $selectedBackend.folder $serverExe)
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

function Get-SamplingProfile {
  # Sampling belongs to the model, not to the launcher. The Qwen family wants
  # topK 20 and the Gemma family wants 64; one hardcoded number is wrong for
  # one of them whichever you pick. A model may carry its own block, and
  # server.json holds the fallback for one that does not.
  param($Model, $ServerConfig)
  $block = $Model.sampling
  $source = "config/models.json ($($Model.alias))"
  if (-not $block) {
    $block = $ServerConfig.sampling
    $source = 'config/server.json (fallback)'
  }
  if (-not $block) { throw 'No sampling block found in config/models.json or config/server.json.' }
  if (-not $block.profile) { throw "The sampling block in $source names no active profile." }
  $values = $block.profiles.($block.profile)
  if (-not $values) { throw "Sampling profile '$($block.profile)' is not defined in $source." }
  # Every knob is sent explicitly, so nothing is inherited from a llama.cpp
  # default that can change between releases. An incomplete profile would
  # silently reintroduce exactly that, so it stops here instead.
  foreach ($key in @('temperature', 'topP', 'topK', 'minP', 'presencePenalty', 'repeatPenalty')) {
    if ($null -eq $values.$key) { throw "Sampling profile '$($block.profile)' in $source is missing '$key'." }
  }
  return [pscustomobject]@{ Name = $block.profile; Source = $source; Values = $values }
}

function Get-CacheType {
  # Mirrors Get-CacheType in llmfit.ps1: the KV cache type is global by default
  # and a model may override it, optionally per platform. This is now only the
  # fallback for a hand-written serve.ps1 command. The launcher asks for the
  # type, sizes its fit table with the answer and sends it on as -CacheType,
  # because a server that loads a different type than the table was drawn with
  # turns that table into a description of a configuration nobody ran.
  param($Model, $ServerConfig, [string]$Platform)
  $block = $Model.cache
  if ($block) {
    $inner = $block.$Platform
    if ($inner -and $inner.type) { return $inner.type }
    if ($block.type) { return $block.type }
  }
  return $ServerConfig.cacheType
}

$sampling = Get-SamplingProfile -Model $model -ServerConfig $serverConfig
$cacheType = if ($CacheType) { $CacheType } else { Get-CacheType -Model $model -ServerConfig $serverConfig -Platform $platform }
$cacheSource = if ($CacheType) { 'passed in' } else { 'resolved from config' }
if (-not $serverConfig.cacheTypeBytes.$cacheType) {
  throw "KV cache type '$cacheType' is not declared in config/server.json cacheTypeBytes. Declared types: $(@($serverConfig.cacheTypeBytes.PSObject.Properties.Name) -join ', ')."
}

Write-Host ''
Write-Host "  Model    : $($model.name)  [$($model.alias)]" -ForegroundColor Cyan
Write-Host "  Backend  : $($selectedBackend.name)" -ForegroundColor Cyan
Write-Host "  Device   : $(if ($Device) { "$Device (pinned, split-mode none)" } else { 'every device the backend enumerates (llama.cpp default split)' })" -ForegroundColor Cyan
Write-Host "  Context  : $($Context / 1024)K tokens" -ForegroundColor Cyan
Write-Host "  Vision   : $(if ($Vision) { 'on (mmproj F16)' } else { 'off' })" -ForegroundColor Cyan
Write-Host "  MTP      : $(if ($Mtp) { if ($mtpPath) { "on (draft model: $($model.mtp.file))" } else { 'on (embedded draft layers)' } } else { 'off' })" -ForegroundColor Cyan
Write-Host "  KV cache : $cacheType  ($cacheSource)" -ForegroundColor Cyan
Write-Host "  Sampling : $($sampling.Name)  [$($sampling.Source)]" -ForegroundColor Cyan
Write-Host ("             temp $($sampling.Values.temperature)  top-p $($sampling.Values.topP)  top-k $($sampling.Values.topK)  min-p $($sampling.Values.minP)  presence $($sampling.Values.presencePenalty)  repeat $($sampling.Values.repeatPenalty)") -ForegroundColor DarkGray
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
  '--cache-type-k', $cacheType
  '--cache-type-v', $cacheType
  '--jinja'
  '--reasoning-preserve'
  '--cache-prompt'
  '--temp', $sampling.Values.temperature
  '--top-p', $sampling.Values.topP
  '--top-k', $sampling.Values.topK
  '--min-p', $sampling.Values.minP
  '--presence-penalty', $sampling.Values.presencePenalty
  '--repeat-penalty', $sampling.Values.repeatPenalty
  '--host', $serverConfig.host
  '--port', $serverConfig.port
)
# Without this llama.cpp splits the model over every device it enumerated, and
# sizes the split with a 'free' figure that never asked the driver what is in
# use. The launcher picked one device and budgeted the fit table against it; not
# sending that choice on would make the table describe a run nobody performed.
if ($Device) { $arguments += @('--device', $Device, '--split-mode', 'none') }
if ($Vision) {
  $arguments += @('--mmproj', $mmprojPath)
  # Raising the encoder's minimum resolution is model specific: Qwen's encoder
  # wants it, Gemma's refuses to load because the floor lands above its own
  # image_max_pixels. Only send it when the catalog asks for it.
  if ($model.imageMinTokens) { $arguments += @('--image-min-tokens', $model.imageMinTokens) }
}
if ($mtpPath) { $arguments += @('--spec-draft-model', $mtpPath) }

& $server @arguments
