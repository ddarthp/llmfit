param(
  [Alias('h')]
  [switch]$Help
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$modelsDirectory = Join-Path $root 'models'
$toolsDirectory = Join-Path $root 'tools'

# ------------------------------------------------------------------- helpers

function ConvertTo-Hashtable {
  param($InputObject)
  if ($null -eq $InputObject) { return $null }

  # When walking an array, every element arrives wrapped in a PSObject, and
  # there '-is [pscustomobject]' is TRUE even for a string. Without unwrapping
  # first, each string in an array became @{Length=N}, which destroyed real
  # config arrays such as mcp.<server>.command in OpenCode.
  $value = $InputObject.PSObject.BaseObject
  if ($null -eq $value) { return $null }
  if ($value -is [string] -or $value -is [ValueType]) { return $value }

  if ($value -is [System.Collections.IDictionary]) {
    $result = [ordered]@{}
    foreach ($key in @($value.Keys)) { $result[$key] = ConvertTo-Hashtable $value[$key] }
    return $result
  }
  if ($value -is [System.Collections.IEnumerable] -and $value -isnot [string]) {
    return @($value | ForEach-Object { ConvertTo-Hashtable $_ })
  }
  # Only walk properties of JSON objects: walking a scalar's properties is how
  # you fall into infinite recursion.
  if ($value -is [System.Management.Automation.PSCustomObject]) {
    $result = [ordered]@{}
    foreach ($property in $InputObject.PSObject.Properties) { $result[$property.Name] = ConvertTo-Hashtable $property.Value }
    return $result
  }
  return $value
}

function Write-Utf8NoBom {
  param([string]$Path, [string]$Content)
  [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

function Read-JsonConfig {
  param([string]$Name)
  $path = Join-Path (Join-Path $root 'config') $Name
  if (-not (Test-Path -LiteralPath $path)) { throw "Missing configuration file: $path" }
  return ConvertTo-Hashtable (Get-Content -Raw -LiteralPath $path | ConvertFrom-Json)
}

function Backup-Once {
  param([string]$Path)
  $backup = "$Path.llmfit-backup"
  if ((Test-Path -LiteralPath $Path) -and -not (Test-Path -LiteralPath $backup)) {
    Copy-Item -LiteralPath $Path -Destination $backup -Force
    Write-Host "  backup saved: $backup" -ForegroundColor DarkGray
  }
}

function Write-Step {
  param([int]$Number, [string]$Title)
  Write-Host ''
  Write-Host "  $Number. $Title" -ForegroundColor Cyan
  Write-Host "  $('-' * 62)" -ForegroundColor DarkCyan
}

function Read-Choice {
  param([string]$Prompt, [int]$Maximum, [int]$Default)
  while ($true) {
    $answer = Read-Host "  $Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    $number = 0
    if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $Maximum) { return $number }
    Write-Host "  Pick a number between 1 and $Maximum." -ForegroundColor Yellow
  }
}

function Get-Sha256 {
  param([string]$Path)
  return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Ensure-Artifact {
  param([string]$Path, [string]$Url, [string]$Sha256)
  $name = Split-Path -Leaf $Path
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null

  # The hash is the contract, not whether the file exists, and not whether curl
  # exited cleanly. Multi-gigabyte downloads get cut off; only the hash decides
  # whether we are done. Attempts 1 and 2 resume where the file left off, and
  # attempt 3 starts over in case the partial data itself is bad.
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    if (Test-Path -LiteralPath $Path) {
      if ((Get-Sha256 -Path $Path) -eq $Sha256) { Write-Host "  OK: $name" -ForegroundColor Green; return }
      if ($attempt -lt 3) {
        Write-Host "  $name is incomplete. Resuming (attempt $attempt of 3)..." -ForegroundColor Yellow
      } else {
        Write-Host "  $name still does not match. Downloading from scratch..." -ForegroundColor Yellow
        Remove-Item -LiteralPath $Path -Force
      }
    } else {
      Write-Host "  Downloading $name..." -ForegroundColor Cyan
    }
    # --retry lets curl ride out transient drops on its own; -C - makes every
    # retry pick up where the file stopped instead of starting again.
    & curl.exe -L --fail --show-error --progress-bar -C - --retry 5 --retry-delay 3 --retry-all-errors -o $Path $Url
    if ($LASTEXITCODE -ne 0) {
      Write-Host "  Transfer interrupted (curl exit $LASTEXITCODE)." -ForegroundColor Yellow
    }
  }

  $actual = Get-Sha256 -Path $Path
  if ($actual -ne $Sha256) {
    throw "Could not download $name after 3 attempts.`nExpected: $Sha256`nGot:      $actual`nURL: $Url"
  }
  Write-Host "  OK: $name" -ForegroundColor Green
}

function Ensure-Backend {
  param([hashtable]$Backend)
  $destination = Join-Path $toolsDirectory $Backend.folder
  if (Test-Path -LiteralPath (Join-Path $destination 'llama-server.exe')) { return }
  Write-Host "  Preparing backend: $($Backend.name)" -ForegroundColor Cyan
  New-Item -ItemType Directory -Force -Path $destination | Out-Null
  foreach ($archive in $Backend.archives) {
    $archivePath = Join-Path (Join-Path $root 'downloads') $archive.file
    Ensure-Artifact -Path $archivePath -Url $archive.url -Sha256 $archive.sha256
    Expand-Archive -LiteralPath $archivePath -DestinationPath $destination -Force
  }
  if (-not (Test-Path -LiteralPath (Join-Path $destination 'llama-server.exe'))) {
    throw "Backend package does not contain llama-server.exe: $destination"
  }
}

# --------------------------------------------------------- device detection

function Get-BackendDevices {
  param([string]$Folder)
  $exe = Join-Path (Join-Path $toolsDirectory $Folder) 'llama-server.exe'
  if (-not (Test-Path -LiteralPath $exe)) { return @() }
  $devices = @()
  try {
    $raw = @(& $exe --list-devices 2>&1)
    if ($env:LLMFIT_DEBUG) {
      Write-Host "  [debug] $Folder returned $($raw.Count) lines" -ForegroundColor Magenta
      foreach ($item in $raw) { Write-Host "  [debug]   <$($item.GetType().Name)> $item" -ForegroundColor Magenta }
    }
    foreach ($line in $raw) {
      # llama.cpp format: "  CUDA0: <device name> (16302 MiB, 15037 MiB free)"
      if ("$line" -match '^\s*(\S+):\s+(.+?)\s+\((\d+)\s+MiB,\s+(\d+)\s+MiB free\)\s*$') {
        $devices += [pscustomobject]@{
          Id = $matches[1]; Name = $matches[2]
          TotalMiB = [int]$matches[3]; FreeMiB = [int]$matches[4]
        }
      }
    }
  } catch {}
  # Careful: PowerShell unrolls a ONE-element array on return, and a scalar has
  # no .Count, so a machine with a SINGLE GPU looked like it had none. That is
  # why EVERY call to this function is wrapped in @().
  return $devices
}

function Format-MiB {
  param([double]$MiB)
  if ($MiB -ge 1024) { return ('{0:N1} GiB' -f ($MiB / 1024)) }
  return ('{0:N0} MiB' -f $MiB)
}

# ---------------------------------------------------------- fit calculation

function Get-KvMiB {
  param([hashtable]$Geometry, [int]$Context, [double]$BytesPerElement)
  # Two terms, because not every layer's cache grows with context:
  #   - kvElementsPerToken scales with the context length
  #   - kvElementsFixed does not (sliding-window layers capped at their window)
  # Both coefficients are derived from the GGUF header and stored in the
  # catalog, so this stays architecture-agnostic. Assuming every layer scales
  # is what makes configurations that fit comfortably look impossible.
  $elements = [double]$Geometry.kvElementsPerToken * $Context + [double]$Geometry.kvElementsFixed
  return ($elements * $BytesPerElement) / 1MB
}

function Get-FileMiB {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return 0 }
  return (Get-Item -LiteralPath $Path).Length / 1MB
}

# --------------------------------------------------------------------- start

$catalog = Read-JsonConfig 'models.json'
$backends = Read-JsonConfig 'backends.json'
$serverConfig = Read-JsonConfig 'server.json'

$apiRoot = "http://$($serverConfig.host):$($serverConfig.port)"
$apiBase = "$apiRoot/v1"
# Keys starting with '_' are documentation inside the catalog, not models.
$modelKeys = @($catalog.Keys | Where-Object { -not $_.StartsWith('_') })
$backendKeys = @($backends.Keys)
$piProvider = $serverConfig.harness.piProvider
$openCodeProvider = $serverConfig.harness.openCodeProvider
$codexProfile = $serverConfig.harness.codexProfile
$deviceReserveMiB = [double]$serverConfig.deviceReserveMiB

if ($Help) {
  Write-Host 'Usage: llmfit'
  Write-Host 'Detects your GPUs and VRAM, lets you pick backend, model, vision and'
  Write-Host 'context, starts llama.cpp and gives you the line to open your harness.'
  Write-Host ''
  Write-Host "Models:   $($modelKeys -join ', ')"
  Write-Host "Backends: $($backendKeys -join ', ')"
  Write-Host "Context:  $(($serverConfig.contextOptions | ForEach-Object { "$($_ / 1024)K" }) -join ', ')"
  Write-Host "API:      $apiBase"
  exit 0
}

Write-Host ''
Write-Host '  LLMFIT' -ForegroundColor Cyan
Write-Host "  $('=' * 62)" -ForegroundColor Cyan

# --------------------------------------------------- 1. ARCHITECTURE / VRAM

Write-Step 1 'AVAILABLE ARCHITECTURES'

$systemRamMiB = 0
try { $systemRamMiB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1MB) } catch {}
Write-Host "  System RAM: $(Format-MiB $systemRamMiB)"
Write-Host ''

$options = @()
foreach ($key in $backendKeys) {
  $backend = $backends[$key]
  $installed = Test-Path -LiteralPath (Join-Path (Join-Path $toolsDirectory $backend.folder) 'llama-server.exe')
  $devices = @(if ($installed) { Get-BackendDevices -Folder $backend.folder } else { @() })
  # NOTE: the 'free' value from --list-devices is static and does not reflect
  # what other processes are using (it reports the same with an empty GPU and
  # with 15 GB in use). The usable budget is total minus the driver reserve,
  # assuming an idle GPU; overhead is calibrated against TOTAL process usage.
  $budget = if ($devices.Count) {
    ($devices | Measure-Object -Property TotalMiB -Maximum).Maximum - $deviceReserveMiB
  } else { $systemRamMiB }
  $options += [pscustomobject]@{
    Key = $key; Backend = $backend; Installed = $installed; Devices = $devices; BudgetMiB = $budget
  }
}

# Recommend from real hardware, not from the backend name.
$recommended = 1
for ($i = 0; $i -lt $options.Count; $i++) {
  if ($options[$i].Key -like 'cuda*' -and $options[$i].Devices.Count) { $recommended = $i + 1; break }
  if ($options[$i].Devices.Count -and $recommended -eq 1 -and $options[$i].Key -ne 'cpu') { $recommended = $i + 1 }
}

for ($i = 0; $i -lt $options.Count; $i++) {
  $option = $options[$i]
  $mark = if (($i + 1) -eq $recommended) { ' [recommended]' } else { '' }
  $state = if ($option.Installed) { '' } else { ' [will be downloaded]' }
  Write-Host ("  {0,2}) {1}{2}{3}" -f ($i + 1), $option.Backend.name, $mark, $state)
  if ($option.Devices.Count) {
    foreach ($device in $option.Devices) {
      Write-Host ("       {0,-8} {1,-28} {2,10} total, {3,10} usable" -f $device.Id, $device.Name, (Format-MiB $device.TotalMiB), (Format-MiB ($device.TotalMiB - $deviceReserveMiB))) -ForegroundColor DarkGray
    }
  } elseif ($option.Key -eq 'cpu') {
    Write-Host ("       no GPU: uses system RAM, {0} nominally free" -f (Format-MiB $systemRamMiB)) -ForegroundColor DarkGray
  } else {
    Write-Host '       no devices detected' -ForegroundColor DarkGray
  }
}

$choice = Read-Choice -Prompt 'Architecture' -Maximum $options.Count -Default $recommended
$selected = $options[$choice - 1]
$backendKey = $selected.Key
$backend = $selected.Backend
Ensure-Backend -Backend $backend
if (-not $selected.Devices.Count -and $backendKey -ne 'cpu') {
  $selected.Devices = @(Get-BackendDevices -Folder $backend.folder)
  if ($selected.Devices.Count) { $selected.BudgetMiB = ($selected.Devices | Measure-Object -Property TotalMiB -Maximum).Maximum - $deviceReserveMiB }
}
$budgetMiB = $selected.BudgetMiB
$budgetLabel = if ($selected.Devices.Count) {
  $best = $selected.Devices | Sort-Object TotalMiB -Descending | Select-Object -First 1
  "$($best.Id) ($($best.Name)), $(Format-MiB $budgetMiB) usable"
} else { "system RAM, $(Format-MiB $budgetMiB)" }

# ------------------------------------------------------ 2. MODEL AND VISION

Write-Step 2 'MODEL'
Write-Host "  Budget: $budgetLabel" -ForegroundColor DarkGray
Write-Host ''

$variants = @()
foreach ($key in $modelKeys) {
  foreach ($vision in @($true, $false)) {
    $item = $catalog[$key]
    $variants += [pscustomobject]@{
      ModelKey = $key; Model = $item; Vision = $vision
      WeightsMiB = Get-FileMiB (Join-Path $modelsDirectory $item.modelFile)
      VisionMiB = if ($vision) { Get-FileMiB (Join-Path $modelsDirectory $item.mmprojFile) } else { 0 }
    }
  }
}

for ($i = 0; $i -lt $variants.Count; $i++) {
  $variant = $variants[$i]
  $visionText = if ($variant.Vision) { 'with vision' } else { 'no vision' }
  $mtpText = if ($variant.Model.mtp) { '  MTP available' } else { '' }
  $sizeText = if ($variant.WeightsMiB) {
    if ($variant.Vision) { "weights $(Format-MiB $variant.WeightsMiB) + vision $(Format-MiB $variant.VisionMiB)" }
    else { "weights $(Format-MiB $variant.WeightsMiB)" }
  } else { 'will be downloaded' }
  Write-Host ("  {0,2}) {1,-28} {2,-11}" -f ($i + 1), $variant.Model.name, $visionText) -NoNewline
  Write-Host "  $sizeText$mtpText" -ForegroundColor DarkGray
}

$choice = Read-Choice -Prompt 'Model' -Maximum $variants.Count -Default 1
$variant = $variants[$choice - 1]
$modelKey = $variant.ModelKey
$model = $variant.Model
$useVision = $variant.Vision

Ensure-Artifact -Path (Join-Path $modelsDirectory $model.modelFile) -Url $model.modelUrl -Sha256 $model.modelSha256
if ($useVision) {
  Ensure-Artifact -Path (Join-Path $modelsDirectory $model.mmprojFile) -Url $model.mmprojUrl -Sha256 $model.mmprojSha256
}
$weightsMiB = Get-FileMiB (Join-Path $modelsDirectory $model.modelFile)
$visionMiB = if ($useVision) { Get-FileMiB (Join-Path $modelsDirectory $model.mmprojFile) } else { 0 }

# -------------------------------------------------------------- 3. CONTEXT

Write-Step 3 'CONTEXT'
$cacheType = $serverConfig.cacheType
$cacheBytes = [double]$serverConfig.cacheTypeBytes[$cacheType]
if (-not $cacheBytes) { throw "Unknown KV cache type in config/server.json: $cacheType" }
Write-Host "  KV quantized to $cacheType ($cacheBytes bytes per element)." -ForegroundColor DarkGray
Write-Host "  $($model.geometry.summary)." -ForegroundColor DarkGray
Write-Host ''

# Overhead calibrated against nvidia-smi. It differs enough between
# architectures that a model may carry its own measured values; the numbers in
# server.json are the fallback for models nobody has measured yet.
$overheadMiB = if ($null -ne $model.overhead.baseMiB) { [double]$model.overhead.baseMiB }
               else { [double]$serverConfig.computeOverheadMiB }
if ($useVision) {
  $overheadMiB += if ($null -ne $model.overhead.visionMiB) { [double]$model.overhead.visionMiB }
                  else { [double]$serverConfig.visionOverheadMiB }
}
$contexts = @()
foreach ($context in $serverConfig.contextOptions) {
  if ($context -gt $model.geometry.maxContext) { continue }
  $kvMiB = Get-KvMiB -Geometry $model.geometry -Context $context -BytesPerElement $cacheBytes
  $totalMiB = $weightsMiB + $visionMiB + $kvMiB + $overheadMiB
  $contexts += [pscustomobject]@{
    Context = $context; KvMiB = $kvMiB; TotalMiB = $totalMiB
    Fits = ($totalMiB -le ($budgetMiB * 0.92)); Tight = ($totalMiB -le $budgetMiB)
  }
}

$defaultContext = 1
for ($i = 0; $i -lt $contexts.Count; $i++) {
  $entry = $contexts[$i]
  $status = if ($entry.Fits) { 'FITS' } elseif ($entry.Tight) { 'TIGHT' } else { 'TOO BIG' }
  $color = if ($entry.Fits) { 'Green' } elseif ($entry.Tight) { 'Yellow' } else { 'Red' }
  if ($entry.Fits) { $defaultContext = $i + 1 }
  Write-Host ("  {0,2}) {1,5}   KV {2,10}   estimated total {3,10}   " -f ($i + 1), "$($entry.Context / 1024)K", (Format-MiB $entry.KvMiB), (Format-MiB $entry.TotalMiB)) -NoNewline
  Write-Host $status -ForegroundColor $color
}

$choice = Read-Choice -Prompt 'Context' -Maximum $contexts.Count -Default $defaultContext
$contextEntry = $contexts[$choice - 1]
$contextSize = $contextEntry.Context

# ------------------------------------------------------------------ 4. MTP

# MTP only pays off on CUDA: on Vulkan the cost of maintaining the draft
# context cancels out the gain. And only if the model ships nextn layers.
# A separate draft model has to fit in memory too, on top of the working
# headroom, so its size is added to what MTP costs.
$mtpHeadroomMiB = 1024
if ($model.mtp -and $model.mtp.bytes) { $mtpHeadroomMiB += [double]$model.mtp.bytes / 1MB }
$useMtp = $false
$mtpReason = ''
if (-not $model.mtp) {
  $mtpReason = "this model ships no MTP layers"
} elseif ($backendKey -notlike 'cuda*') {
  $mtpReason = "only enabled on CUDA (you picked $backendKey)"
} elseif (($budgetMiB - $contextEntry.TotalMiB) -lt $mtpHeadroomMiB) {
  $margin = $budgetMiB - $contextEntry.TotalMiB
  $mtpReason = if ($margin -lt 0) {
    "this configuration already exceeds VRAM by $(Format-MiB ([math]::Abs($margin)))"
  } else {
    "only $(Format-MiB $margin) left over, $(Format-MiB $mtpHeadroomMiB) needed"
  }
} else {
  $useMtp = $true
  $mtpReason = "CUDA with $(Format-MiB ($budgetMiB - $contextEntry.TotalMiB)) of headroom"
}

Write-Step 4 'SPECULATIVE DECODING (MTP)'
if ($useMtp) {
  Write-Host "  Enabled: $mtpReason" -ForegroundColor Green
  if ($model.mtp.mode -eq 'draft-model') {
    Write-Host "  Draft model: $($model.mtp.file)" -ForegroundColor DarkGray
    Ensure-Artifact -Path (Join-Path $modelsDirectory $model.mtp.file) -Url $model.mtp.url -Sha256 $model.mtp.sha256
  }
} else {
  Write-Host "  Disabled: $mtpReason" -ForegroundColor DarkGray
}

# -------------------------------------------------------------- 5. HARNESS

. (Join-Path $root 'lib\harness.ps1')

Write-Step 5 'HARNESS'
$harnesses = Get-Harnesses -Alias $model.alias -ApiRoot $apiRoot -ApiBase $apiBase `
  -PiProvider $piProvider -OpenCodeProvider $openCodeProvider -CodexProfile $codexProfile

for ($i = 0; $i -lt $harnesses.Count; $i++) {
  $harness = $harnesses[$i]
  $state = if (-not $harness.Installed) { '[not installed]' } elseif (-not $harness.Supported) { '[incompatible]' } else { '[installed]' }
  $color = if ($harness.Installed -and $harness.Supported) { 'White' } else { 'DarkGray' }
  Write-Host ("  {0,2}) {1,-14} {2,-16} {3}" -f ($i + 1), $harness.Name, $state, $harness.Api) -ForegroundColor $color
  if (-not $harness.Supported) { Write-Host "       $($harness.SupportNote)" -ForegroundColor DarkGray }
}
Write-Host ("  {0,2}) None, server only" -f ($harnesses.Count + 1))

$choice = Read-Choice -Prompt 'Harness' -Maximum ($harnesses.Count + 1) -Default 1
$chosen = if ($choice -le $harnesses.Count) { $harnesses[$choice - 1] } else { $null }

if ($chosen -and -not $chosen.Supported) {
  Write-Host ''
  Write-Host "  WARNING: $($chosen.Name) does not work against this model." -ForegroundColor Yellow
  Write-Host "  $($chosen.SupportNote)" -ForegroundColor Yellow
  Write-Host '  The line is shown anyway, but expect HTTP 500 on the first message.' -ForegroundColor Yellow
}

if ($chosen -and $chosen.Configure) {
  Write-Host ''
  Write-Host "  Registering the local provider in $($chosen.Name)..." -ForegroundColor Cyan
  & $chosen.Configure $catalog $apiBase $serverConfig
}

# ---------------------------------------------------------- start the server

$running = Get-CimInstance Win32_Process -Filter "Name='llama-server.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($toolsDirectory, [System.StringComparison]::OrdinalIgnoreCase) }
if ($running) {
  Write-Host ''
  $stop = Read-Host '  A local llama-server is already running. Stop it and load this configuration? [Y/n]'
  if ([string]::IsNullOrWhiteSpace($stop) -or $stop -match '^[sSyY]') {
    $running | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
    Start-Sleep -Seconds 2
  } else {
    throw 'Cancelled so the running server is not replaced.'
  }
}

$serverArgs = @(
  '-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit',
  '-File', ('"' + (Join-Path $root 'serve.ps1') + '"'),
  '-ModelKey', $modelKey, '-Backend', $backendKey, '-Context', $contextSize
)
if ($useVision) { $serverArgs += '-Vision' }
if ($useMtp) { $serverArgs += '-Mtp' }

$powerShellHost = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
Start-Process -FilePath $powerShellHost -ArgumentList $serverArgs -WorkingDirectory $root -WindowStyle Normal | Out-Null

Write-Host ''
Write-Host '  Loading the model...' -ForegroundColor Cyan
$ready = $false
for ($attempt = 0; $attempt -lt 300; $attempt++) {
  try {
    if ((Invoke-RestMethod -Uri "$apiRoot/health" -TimeoutSec 2).status -eq 'ok') { $ready = $true; break }
  } catch {}
  Start-Sleep -Seconds 1
}
if (-not $ready) { throw "llama.cpp was not ready within 300 seconds. Check the server window." }

# ------------------------------------------------------------------ summary

Write-Host ''
Write-Host "  $('=' * 62)" -ForegroundColor Green
Write-Host '  SERVER RUNNING' -ForegroundColor Green
Write-Host "  $('=' * 62)" -ForegroundColor Green
Write-Host "  Model     : $($model.alias)  ($(if ($useVision) { 'with vision' } else { 'no vision' }))"
Write-Host "  Backend   : $backendKey  -  $budgetLabel"
Write-Host "  Context   : $($contextSize / 1024)K   (KV $cacheType, $(Format-MiB $contextEntry.KvMiB))"
Write-Host "  MTP       : $(if ($useMtp) { 'enabled' } else { 'disabled' })"
Write-Host "  API       : $apiBase"
Write-Host "  Chat UI   : $apiRoot  (built into llama.cpp, always available)"
Write-Host '  The server stays in its own window. Leave it open.' -ForegroundColor DarkGray

if ($chosen) {
  Write-Host ''
  $heading = if ($chosen.OpenUrl) { '  YOUR CHAT UI:' } else { '  OPEN ANY FOLDER AND PASTE THIS:' }
  Write-Host $heading -ForegroundColor Cyan
  Write-Host ''
  Write-Host "    $($chosen.Line)" -ForegroundColor Yellow
  Write-Host ''
  try {
    Set-Clipboard -Value $chosen.Line -ErrorAction Stop
    Write-Host '    (already in your clipboard)' -ForegroundColor DarkGray
  } catch {}
  if ($chosen.Note) { Write-Host "    $($chosen.Note)" -ForegroundColor DarkGray }
  if ($chosen.OpenUrl) {
    Start-Process $chosen.OpenUrl | Out-Null
    Write-Host ''
    Write-Host '    Opening it now...' -ForegroundColor DarkGray
  }
}

Write-Host ''
Write-Host '  OTHER HARNESSES AGAINST THIS SAME SERVER' -ForegroundColor Cyan
foreach ($harness in $harnesses) {
  if ($chosen -and $harness.Name -eq $chosen.Name) { continue }
  $state = if (-not $harness.Installed) { 'not installed' }
    elseif (-not $harness.Supported) { 'incompatible with this chat template' }
    elseif ($harness.Configure -and -not (& $harness.IsConfigured $serverConfig)) { "run llmfit and pick $($harness.Name)" }
    else { 'ready' }
  Write-Host ("    {0,-13} {1}" -f $harness.Name, $harness.Line) -ForegroundColor DarkGray
  Write-Host ("    {0,-13} -> {1}" -f '', $state) -ForegroundColor DarkGray
}

Write-Host ''
Write-Host '  STOP THE SERVER' -ForegroundColor Cyan
Write-Host '    Get-Process llama-server | Stop-Process -Force' -ForegroundColor DarkGray
Write-Host ''
