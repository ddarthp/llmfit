param(
  [Parameter(Mandatory = $true)][string]$ModelKey,
  [Parameter(Mandatory = $true)][string]$Backend,
  [int]$Context = 0,
  [string]$Device = '',
  [string]$CacheType = '',
  # How many layers' experts to keep in system RAM. Resolved by the fit table
  # rather than chosen here, for the same reason -CacheType is passed in: the
  # table was drawn against a number, and the server has to load the same one or
  # the table described a run nobody performed. 0 leaves every expert on the GPU,
  # which is what this script did before the flag existed.
  [int]$NCpuMoe = 0,
  [switch]$Vision,
  # Named -Mtp while draft weights were the only speculative method here. It now
  # also turns on model-free methods, which are not MTP, so the name widened;
  # the alias keeps every existing caller - llmfit.ps1 included - working.
  [Alias('Mtp')][switch]$Spec
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$configDirectory = Join-Path $root 'config'

# Windows PowerShell 5.1 defines none of $IsWindows, $IsMacOS and $IsLinux, and
# only ever runs on Windows, so their absence answers the question. See llmfit.ps1.
$onWindows = if ($null -ne $IsWindows) { [bool]$IsWindows } else { $true }
$onMacOS = if ($null -ne $IsMacOS) { [bool]$IsMacOS } else { $false }
$onLinux = if ($null -ne $IsLinux) { [bool]$IsLinux } else { $false }
$platform = if ($onMacOS) { 'macos' } elseif ($onLinux) { 'linux' } else { 'windows' }
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
if ($Spec -and -not ($model.mtp -or $model.speculative)) {
  throw "$($model.name) ships no MTP layers and declares no model-free speculative method: speculative decoding cannot be enabled."
}
# The launcher never offers MTP on a backend whose speculativeDecoding is false,
# so only a hand-written command reaches this. It has to stop here: measured on
# b10566, Gemma 4's draft model on Vulkan does not run slowly, it aborts the
# process inside ggml-backend.cpp with 'pre-allocated tensor (cache_k_l22) in a
# buffer (Vulkan0) that cannot run the operation'. A thrown message beats a
# stack trace from a crash the catalog already knew was coming.
if ($Spec -and -not $selectedBackend.speculativeDecoding) {
  throw "Speculative decoding is not available on the $Backend backend. config/backends.json sets speculativeDecoding false there, and the comment beside it says why."
}

$server = Join-Path (Join-Path $root 'tools') (Join-Path $selectedBackend.folder $serverExe)
$modelPath = Join-Path (Join-Path $root 'models') $model.modelFile
$required = @($server, $modelPath)
$mmprojPath = Join-Path (Join-Path $root 'models') $model.mmprojFile
if ($Vision) { $required += $mmprojPath }
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

function Get-SpecType {
  # Which speculative method llama-server is asked for. Two shapes reach here:
  # a model that ships draft weights declares 'mtp' and wants draft-mtp, and a
  # model with no drafter at all can still declare a model-free method in
  # 'speculative.specType' - an ngram variant drafts from the tokens already in
  # the context window, so it needs no weights and no companion file. The
  # model-free block wins when both exist, because a catalog that bothered to
  # name a method has measured it. Overridable per platform in the same shape as
  # the cache block, since nothing about speculation travelled between backends.
  param($Model, [string]$Platform)
  $block = $Model.speculative
  if ($block) {
    $inner = $block.$Platform
    if ($inner -and $inner.specType) { return $inner.specType }
    if ($block.specType) { return $block.specType }
  }
  if ($Model.mtp) { return 'draft-mtp' }
  return 'none'
}

$sampling = Get-SamplingProfile -Model $model -ServerConfig $serverConfig
$cacheType = if ($CacheType) { $CacheType } else { Get-CacheType -Model $model -ServerConfig $serverConfig -Platform $platform }
$cacheSource = if ($CacheType) { 'passed in' } else { 'resolved from config' }
if (-not $serverConfig.cacheTypeBytes.$cacheType) {
  throw "KV cache type '$cacheType' is not declared in config/server.json cacheTypeBytes. Declared types: $(@($serverConfig.cacheTypeBytes.PSObject.Properties.Name) -join ', ')."
}

$specType = if ($Spec) { Get-SpecType -Model $model -Platform $platform } else { 'none' }
# Gemma 4 ships MTP as a separate draft model; Qwen embeds it in the main file.
# The resolved method decides whether that file is needed at all, so a model
# that also names a model-free method never demands a draft it will not load.
$mtpPath = $null
if ($specType -eq 'draft-mtp' -and $model.mtp.mode -eq 'draft-model') {
  $mtpPath = Join-Path (Join-Path $root 'models') $model.mtp.file
  if (-not (Test-Path -LiteralPath $mtpPath)) { throw "Not found: $mtpPath" }
}

# Report the method actually in use. A model-free ngram run is not MTP, and a
# line that says otherwise describes a configuration nobody launched.
$specText = 'off'
if ($Spec) {
  if ($mtpPath) { $specText = "$specType (draft model: $($model.mtp.file))" }
  elseif ($specType -eq 'draft-mtp') { $specText = "$specType (embedded draft layers)" }
  else { $specText = "$specType (model-free, no draft weights)" }
}

Write-Host ''
Write-Host "  Model    : $($model.name)  [$($model.alias)]" -ForegroundColor Cyan
Write-Host "  Backend  : $($selectedBackend.name)" -ForegroundColor Cyan
Write-Host "  Device   : $(if ($Device) { "$Device (pinned, split-mode none)" } else { 'every device the backend enumerates (llama.cpp default split)' })" -ForegroundColor Cyan
Write-Host "  Context  : $($Context / 1024)K tokens" -ForegroundColor Cyan
Write-Host "  Vision   : $(if ($Vision) { 'on (mmproj F16)' } else { 'off' })" -ForegroundColor Cyan
Write-Host "  Spec dec : $specText" -ForegroundColor Cyan
Write-Host "  KV cache : $cacheType  ($cacheSource)" -ForegroundColor Cyan
Write-Host "  Experts  : $(if ($NCpuMoe -gt 0) { "first $NCpuMoe layers in system RAM (--n-cpu-moe)" } else { 'all on the GPU' })" -ForegroundColor Cyan
Write-Host "  Sampling : $($sampling.Name)  [$($sampling.Source)]" -ForegroundColor Cyan
Write-Host ("             temp $($sampling.Values.temperature)  top-p $($sampling.Values.topP)  top-k $($sampling.Values.topK)  min-p $($sampling.Values.minP)  presence $($sampling.Values.presencePenalty)  repeat $($sampling.Values.repeatPenalty)") -ForegroundColor DarkGray
# The bind address is not an address anything connects to; see lib/net.ps1.
# This window is often the only thing on screen when serve.ps1 is run directly,
# so it answers 'where is it' the same way the launcher's summary does.
. (Join-Path $root (Join-Path 'lib' 'net.ps1'))
$endpoint = Get-ServerEndpoint -ServerConfig $serverConfig -OnWindows $onWindows -OnMacOS $onMacOS -OnLinux $onLinux
Write-Host "  API      : $($endpoint.LocalRoot)/v1" -ForegroundColor Cyan
if ($endpoint.IsWildcard -and $endpoint.LanAddresses.Count) {
  Write-Host "  LAN      : $($endpoint.LanRoots[0])/v1$(if ($endpoint.MdnsRoot) { "   or $($endpoint.MdnsRoot)/v1" })" -ForegroundColor Cyan
} elseif (-not $endpoint.IsWildcard) {
  Write-Host "  LAN      : off - bound to $($endpoint.BindHost)" -ForegroundColor DarkGray
}
Write-Host ''

# Anything reported on screen is set by an explicit flag. Inheriting a default
# that can change between llama.cpp releases is not a guarantee.
$arguments = @(
  '--model', $modelPath
  '--alias', $model.alias
  '--ctx-size', $Context
  '--parallel', 1
  '--gpu-layers', $selectedBackend.gpuLayers
  '--spec-type', $specType
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
# Expert offload, and note what it is NOT: this does not split the model across
# devices, and it is not a second GPU. It moves the expert FFN tensors of the
# first N layers into system RAM, where the CPU computes them. It only pays on a
# mixture of experts, where a fraction of the experts run per token - 8 of 256 on
# the Qwen 35B - so the weights that moved are mostly read by nobody on any given
# token. Sending it for a dense model would move layers that run every time.
if ($NCpuMoe -gt 0) { $arguments += @('--n-cpu-moe', $NCpuMoe) }
if ($Vision) {
  $arguments += @('--mmproj', $mmprojPath)
  # Raising the encoder's minimum resolution is model specific: Qwen's encoder
  # wants it, Gemma's refuses to load because the floor lands above its own
  # image_max_pixels. Only send it when the catalog asks for it.
  if ($model.imageMinTokens) { $arguments += @('--image-min-tokens', $model.imageMinTokens) }
}
if ($mtpPath) { $arguments += @('--spec-draft-model', $mtpPath) }

& $server @arguments
