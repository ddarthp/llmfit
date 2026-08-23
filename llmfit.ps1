param(
  [Alias('h')]
  [switch]$Help
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$modelsDirectory = Join-Path $root 'models'
$toolsDirectory = Join-Path $root 'tools'

# ------------------------------------------------------------------ platform

# $IsWindows and $IsMacOS are PowerShell 7 automatic variables. Windows
# PowerShell 5.1 does not define them at all, and that absence is itself the
# answer: 5.1 only ever runs on Windows. They cannot be assigned to, because
# PowerShell 7 makes them read-only, hence the separate names.
$onWindows = if ($null -ne $IsWindows) { [bool]$IsWindows } else { $true }
$onMacOS = if ($null -ne $IsMacOS) { [bool]$IsMacOS } else { $false }
$platform = if ($onMacOS) { 'macos' } else { 'windows' }
$exeSuffix = if ($onWindows) { '.exe' } else { '' }
$serverExe = "llama-server$exeSuffix"
# On Windows the bundled curl is curl.exe; invoking it unqualified would find
# the PowerShell alias for Invoke-WebRequest instead, which takes none of these
# flags. On macOS there is no such alias and the binary is plain curl.
$curlCommand = if ($onWindows) { 'curl.exe' } else { 'curl' }

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
    & $curlCommand -L --fail --show-error --progress-bar -C - --retry 5 --retry-delay 3 --retry-all-errors -o $Path $Url
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

function Expand-Package {
  param([string]$ArchivePath, [string]$Destination, [int]$StripComponents = 0)
  # The Windows backends ship as zips that extract flat. The macOS backend is a
  # tar.gz whose contents sit one directory down, under llama-b<build>, so it
  # asks for that level to be stripped and lands flat like the others.
  # Expand-Archive cannot read a tar.gz at all, and tar preserves the execute
  # bit that a Mach-O binary needs, which is the other reason not to unify them.
  if ($ArchivePath -match '\.(tar\.gz|tgz)$') {
    $tarArguments = @('-xzf', $ArchivePath, '-C', $Destination)
    if ($StripComponents -gt 0) { $tarArguments += "--strip-components=$StripComponents" }
    & tar @tarArguments
    if ($LASTEXITCODE -ne 0) { throw "Could not extract $ArchivePath (tar exit $LASTEXITCODE)" }
  } else {
    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $Destination -Force
  }
}

function Ensure-Backend {
  param([hashtable]$Backend)
  $destination = Join-Path $toolsDirectory $Backend.folder
  if (Test-Path -LiteralPath (Join-Path $destination $serverExe)) { return }
  Write-Host "  Preparing backend: $($Backend.name)" -ForegroundColor Cyan
  New-Item -ItemType Directory -Force -Path $destination | Out-Null
  foreach ($archive in $Backend.archives) {
    $archivePath = Join-Path (Join-Path $root 'downloads') $archive.file
    Ensure-Artifact -Path $archivePath -Url $archive.url -Sha256 $archive.sha256
    $strip = if ($archive.stripComponents) { [int]$archive.stripComponents } else { 0 }
    Expand-Package -ArchivePath $archivePath -Destination $destination -StripComponents $strip
  }
  if (-not (Test-Path -LiteralPath (Join-Path $destination $serverExe))) {
    throw "Backend package does not contain ${serverExe}: $destination"
  }
}

# --------------------------------------------------------- device detection

function Get-BackendDevices {
  param([string]$Folder)
  $exe = Join-Path (Join-Path $toolsDirectory $Folder) $serverExe
  if (-not (Test-Path -LiteralPath $exe)) { return @() }
  $devices = @()
  try {
    $raw = @(& $exe --list-devices 2>&1)
    if ($env:LLMFIT_DEBUG) {
      Write-Host "  [debug] $Folder returned $($raw.Count) lines" -ForegroundColor Magenta
      foreach ($item in $raw) { Write-Host "  [debug]   <$($item.GetType().Name)> $item" -ForegroundColor Magenta }
    }
    foreach ($line in $raw) {
      # One format covers every backend, which is why Metal needed no new parser:
      #   CUDA0: NVIDIA GeForce RTX 5070 Ti (16302 MiB, 15037 MiB free)
      #   MTL0:  Apple M4 Pro               (18186 MiB, 18185 MiB free)
      if ("$line" -match '^\s*(\S+):\s+(.+?)\s+\((\d+)\s+MiB,\s+(\d+)\s+MiB free\)\s*$') {
        # Metal also lists "BLAS: Accelerate (0 MiB, 0 MiB free)", a compute
        # library rather than a device with memory of its own. It matches the
        # pattern perfectly and would show up in the menu as a GPU with no
        # memory, so anything reporting no memory is not a device to budget for.
        if ([int]$matches[3] -le 0) { continue }
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

function Get-LiveFreeMiB {
  # nvidia-smi reports free memory as it is right now. llama.cpp's
  # --list-devices does not: its 'free' is static and ignores every other
  # process. Preferring the live number is what stops the fit table from
  # promising memory a browser or another model already took.
  try {
    $raw = & nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>$null
    if ($LASTEXITCODE -eq 0 -and $raw) {
      $values = @($raw | ForEach-Object { [double]($_.ToString().Trim()) } | Where-Object { $_ -gt 0 })
      if ($values.Count) { return ($values | Measure-Object -Maximum).Maximum }
    }
  } catch {}
  return $null
}

function ConvertTo-ShellQuoted {
  # Single quotes are the only construct sh does not interpret anything inside,
  # so wrapping in them and closing-escaping-reopening around any embedded
  # quote makes a path safe whatever it contains. Needed because the macOS
  # server launch goes through sh -c; see the comment where it is built.
  param([string]$Value)
  return "'" + $Value.Replace("'", "'\''") + "'"
}

function Get-PlatformSetting {
  # Any config block may carry a sub-block named after a platform, and a value
  # there wins over the same key at the top level. Almost nothing measured on
  # one backend turned out to hold on the other - what MTP costs, how far up the
  # context range it survives, whether it is worth enabling, whether quantizing
  # the KV cache is free or ruinous - so the shape is shared rather than
  # reinvented per setting. On Windows there is no 'windows' sub-block unless
  # someone writes one, and every lookup falls through to the top level.
  param($Block, [string]$Platform, [string]$Name)
  if (-not $Block) { return $null }
  if ($Block.Contains($Platform)) {
    $inner = $Block[$Platform]
    if ($inner -and $inner.Contains($Name) -and $null -ne $inner[$Name]) { return $inner[$Name] }
  }
  if ($Block.Contains($Name)) { return $Block[$Name] }
  return $null
}

function Get-CacheType {
  # The KV cache type is global by default and overridable per model, because
  # what it costs is not a property of the launcher. Quantizing it was measured
  # on CUDA to move attention off the GPU and collapse prompt processing from
  # 3355 to 40 tokens per second, so a model that wants a quantized cache
  # usually wants it on one platform and not the other.
  param($Model, $ServerConfig, [string]$Platform)
  $type = Get-PlatformSetting -Block $Model.cache -Platform $Platform -Name 'type'
  if ($type) { return @{ Type = $type; Source = "config/models.json ($($Model.alias))" } }
  return @{ Type = $ServerConfig.cacheType; Source = 'config/server.json' }
}

function Get-SystemRamMiB {
  # Win32_ComputerSystem is a WMI class and does not exist off Windows; the
  # macOS answer comes from sysctl, which is always present.
  try {
    if ($onWindows) {
      return [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1MB)
    }
    $bytes = [double](& sysctl -n hw.memsize)
    if ($bytes -gt 0) { return [math]::Round($bytes / 1MB) }
  } catch {}
  return 0
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
# Only the backends that can run here. A CUDA zip is not something a Mac should
# be offered and then fail to execute.
$backendKeys = @($backends.Keys | Where-Object {
  -not $_.StartsWith('_') -and $backends[$_].platform -eq $platform
})
if (-not $backendKeys.Count) {
  throw "config/backends.json declares no backend for platform '$platform'."
}
$piProvider = $serverConfig.harness.piProvider
$openCodeProvider = $serverConfig.harness.openCodeProvider
$codexProfile = $serverConfig.harness.codexProfile

# What --list-devices calls 'total' is raw dedicated VRAM on Windows and the
# already-conservative recommendedMaxWorkingSetSize on Metal, so the constants
# that turn it into a budget are per platform. See config/server.json.
$platformConfig = $serverConfig.platforms[$platform]
if (-not $platformConfig) { throw "config/server.json has no platforms.$platform block." }
$deviceReserveMiB = [double]$platformConfig.deviceReserveMiB
$safetyMarginPercent = [double]$platformConfig.safetyMarginPercent

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

$systemRamMiB = Get-SystemRamMiB
Write-Host "  System RAM: $(Format-MiB $systemRamMiB)"
if ($onMacOS) {
  Write-Host '  Apple Silicon shares that RAM with the GPU. The budget below is the slice' -ForegroundColor DarkGray
  Write-Host '  macOS recommends a single process keep resident, not a separate pool.' -ForegroundColor DarkGray
}
Write-Host ''

$options = @()
foreach ($key in $backendKeys) {
  $backend = $backends[$key]
  $installed = Test-Path -LiteralPath (Join-Path (Join-Path $toolsDirectory $backend.folder) $serverExe)
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
    # Calling the Metal figure 'total' would be a lie: on a 24 GiB Mac it reads
    # 18186 MiB, because it is what macOS recommends a process keep resident,
    # not the size of the machine. On Windows it really is the card's total.
    $totalLabel = if ($onMacOS) { 'recommended' } else { 'total' }
    foreach ($device in $option.Devices) {
      Write-Host ("       {0,-8} {1,-28} {2,10} {3}, {4,10} usable" -f $device.Id, $device.Name, (Format-MiB $device.TotalMiB), $totalLabel, (Format-MiB ($device.TotalMiB - $deviceReserveMiB))) -ForegroundColor DarkGray
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
$budgetSource = if ($onMacOS) { 'what macOS recommends one process keep resident' }
                else { 'total minus driver reserve' }
$best = if ($selected.Devices.Count) { $selected.Devices | Sort-Object TotalMiB -Descending | Select-Object -First 1 } else { $null }
if ($best -and $best.Name -match 'NVIDIA') {
  $live = Get-LiveFreeMiB
  # Only trust the live figure when it is lower: it means something else is on
  # the card and we would otherwise overcommit.
  if ($null -ne $live -and $live -lt $budgetMiB) {
    $budgetMiB = $live
    $budgetSource = 'free right now, other processes are using the card'
  }
}
# Hold back a slice of the card. Windows will not hand a single process the
# last of the dedicated VRAM; it silently pages the excess into system RAM,
# where there is no error to see and generation just crawls.
$safetyMiB = 0
if ($best -and $safetyMarginPercent -gt 0) {
  $safetyMiB = [math]::Round($best.TotalMiB * $safetyMarginPercent / 100)
  $budgetMiB = $budgetMiB - $safetyMiB
}
$budgetLabel = if ($best) {
  "$($best.Id) ($($best.Name)), $(Format-MiB $budgetMiB) usable"
} else { "system RAM, $(Format-MiB $budgetMiB)" }
if ($safetyMiB -gt 0) { $budgetSource += ", holding back $(Format-MiB $safetyMiB)" }

# ------------------------------------------------------ 2. MODEL AND VISION

Write-Step 2 'MODEL'
Write-Host "  Budget: $budgetLabel  [$budgetSource]" -ForegroundColor DarkGray
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
$cacheChoice = Get-CacheType -Model $model -ServerConfig $serverConfig -Platform $platform
$cacheType = $cacheChoice.Type
$cacheBytes = [double]$serverConfig.cacheTypeBytes[$cacheType]
if (-not $cacheBytes) {
  throw "Unknown KV cache type '$cacheType' from $($cacheChoice.Source). Declared types: $(@($serverConfig.cacheTypeBytes.Keys) -join ', ')"
}
# The collapse a quantized KV cache causes was measured on CUDA, where flash
# attention has no kernel for one and silently moves attention to the CPU. It
# has not been measured on Metal, so it is not asserted there.
$cacheNote = if ($cacheType -like 'f*' -or $cacheType -like 'bf*') {
  'full precision, attention stays on the GPU'
} elseif ($onMacOS) {
  'QUANTIZED: costs prompt speed on CUDA; unmeasured on Metal'
} else {
  'QUANTIZED: attention falls back to the CPU on CUDA'
}
Write-Host "  KV cache in $cacheType, $cacheBytes bytes per element ($cacheNote)." -ForegroundColor DarkGray
if ($cacheChoice.Source -ne 'config/server.json') {
  Write-Host "  That type is set for this model in $($cacheChoice.Source), not globally." -ForegroundColor DarkGray
}
Write-Host "  $($model.geometry.summary)." -ForegroundColor DarkGray
Write-Host ''

# Overhead calibrated against nvidia-smi. It differs enough between
# architectures that a model may carry its own measured values; the numbers in
# server.json are the fallback for models nobody has measured yet.
#
# Those measurements were all taken on CUDA. A model may carry a block measured
# on another platform under that platform's name, and when it does not, the
# CUDA constants are the best available guess rather than a calibrated figure.
# The gap is not cosmetic on Apple Silicon: the negative base overheads encode
# "part of this file never reaches VRAM", and on unified memory there is no
# transfer for that statement to be about.
$overheadBlock = $model.overhead
$overheadCalibrated = $true
if (-not $overheadBlock) {
  # A model nobody has measured at all, on any platform. It still runs; the
  # estimate just inherits constants fitted to a different model.
  $overheadCalibrated = $false
} elseif (-not $onWindows) {
  $platformBlock = $null
  if ($overheadBlock.Contains($platform)) { $platformBlock = $overheadBlock[$platform] }
  if ($platformBlock) { $overheadBlock = $platformBlock } else { $overheadCalibrated = $false }
}
$overheadMiB = if ($overheadBlock -and $null -ne $overheadBlock.baseMiB) { [double]$overheadBlock.baseMiB }
               else { [double]$serverConfig.computeOverheadMiB }
if ($useVision) {
  $overheadMiB += if ($overheadBlock -and $null -ne $overheadBlock.visionMiB) { [double]$overheadBlock.visionMiB }
                  else { [double]$serverConfig.visionOverheadMiB }
}
if (-not $overheadCalibrated) {
  $what = if ($model.overhead) { "measured on this platform" } else { "measured for this model" }
  Write-Host "  NOTE: no overhead $what yet, so constants fitted to something" -ForegroundColor Yellow
  Write-Host '  else are standing in. The KV column is exact; the estimated total is a guess' -ForegroundColor Yellow
  Write-Host "  until someone measures it here and writes it into models.json." -ForegroundColor Yellow
  Write-Host ''
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

# Whether MTP pays off is a property of the backend, measured per backend and
# declared in config/backends.json rather than inferred from its name: on
# Vulkan the cost of maintaining the draft context cancels out the gain. And
# only if the model ships nextn layers.
# What MTP costs is measured per model and differs by an order of magnitude:
# an embedded draft context is built against the whole model, a companion draft
# file is small. Counting it as free is how a configuration that reports FITS
# ends up spilling into system RAM.
#
# Every setting below can be overridden per platform, because none of them
# turned out to travel: the same model's embedded MTP costs 1200 MiB on CUDA
# and 817 on Metal, and is worth enabling on one and not the other.
$mtpCostRaw = Get-PlatformSetting -Block $model.mtp -Platform $platform -Name 'costMiB'
$mtpCostMiB = if ($mtpCostRaw) { [double]$mtpCostRaw } else { 512 }
$mtpAutoEnable = Get-PlatformSetting -Block $model.mtp -Platform $platform -Name 'autoEnable'
$mtpMaxContext = Get-PlatformSetting -Block $model.mtp -Platform $platform -Name 'maxContext'
$mtpNote = Get-PlatformSetting -Block $model.mtp -Platform $platform -Name 'note'
$mtpHeadroomMiB = $mtpCostMiB + 256
$useMtp = $false
$mtpReason = ''
if (-not $model.mtp) {
  $mtpReason = "this model ships no MTP layers"
} elseif ($mtpAutoEnable -eq $false) {
  $mtpReason = "turned off for this model in config/models.json"
} elseif ($backend.speculativeDecoding -ne $true) {
  $mtpReason = "not enabled for the $backendKey backend in config/backends.json"
} elseif ($mtpMaxContext -and $contextSize -gt [int]$mtpMaxContext) {
  # A ceiling that was measured, not derived. costMiB is modelled as a flat
  # number, but an embedded draft context carries its own KV cache and so grows
  # with the context length: the memory check below would wave through a
  # configuration that loads, reports healthy, and then dies on its first
  # decode. Until the cost is modelled per token, the honest bound is the
  # longest context somebody actually ran.
  $mtpReason = "only verified up to $([int]$mtpMaxContext / 1024)K on $platform and you picked $($contextSize / 1024)K"
} elseif (($budgetMiB - $contextEntry.TotalMiB) -lt $mtpHeadroomMiB) {
  $margin = $budgetMiB - $contextEntry.TotalMiB
  $mtpReason = if ($margin -lt 0) {
    "this configuration already exceeds the budget by $(Format-MiB ([math]::Abs($margin)))"
  } else {
    "it costs $(Format-MiB $mtpCostMiB) and only $(Format-MiB $margin) is left over"
  }
} else {
  $useMtp = $true
  $mtpReason = "costs $(Format-MiB $mtpCostMiB), leaving $(Format-MiB ($budgetMiB - $contextEntry.TotalMiB - $mtpCostMiB)) free"
}

Write-Step 4 'SPECULATIVE DECODING (MTP)'
if ($useMtp) {
  Write-Host "  Enabled: $mtpReason" -ForegroundColor Green
  # What the catalog knows about this combination that the memory check cannot
  # express, such as it having been measured to buy nothing.
  if ($mtpNote) { Write-Host "  $mtpNote" -ForegroundColor Yellow }
  if ($model.mtp.mode -eq 'draft-model') {
    Write-Host "  Draft model: $($model.mtp.file)" -ForegroundColor DarkGray
    Ensure-Artifact -Path (Join-Path $modelsDirectory $model.mtp.file) -Url $model.mtp.url -Sha256 $model.mtp.sha256
  }
} else {
  Write-Host "  Disabled: $mtpReason" -ForegroundColor DarkGray
}

# -------------------------------------------------------------- 5. HARNESS

. (Join-Path $root (Join-Path 'lib' 'harness.ps1'))

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
  & $chosen.Configure $model $contextSize $apiBase $serverConfig
}

# ---------------------------------------------------------- start the server

$runningIds = @()
if ($onWindows) {
  $runningIds = @(Get-CimInstance Win32_Process -Filter "Name='llama-server.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($toolsDirectory, [System.StringComparison]::OrdinalIgnoreCase) } |
    ForEach-Object { $_.ProcessId })
} else {
  # Win32_Process is a WMI class and exists only on Windows. Get-Process gives
  # the one thing that matters here anyway: the path the process was started
  # from, which is how a server this launcher owns is told apart from someone
  # else's llama-server on the same machine.
  $runningIds = @(Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and $_.Path.StartsWith($toolsDirectory, [System.StringComparison]::OrdinalIgnoreCase) } |
    ForEach-Object { $_.Id })
}
if ($runningIds.Count) {
  Write-Host ''
  $stop = Read-Host '  A local llama-server is already running. Stop it and load this configuration? [Y/n]'
  if ([string]::IsNullOrWhiteSpace($stop) -or $stop -match '^[sSyY]') {
    $runningIds | ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2
  } else {
    throw 'Cancelled so the running server is not replaced.'
  }
}

$serveScript = Join-Path $root 'serve.ps1'
$serveArguments = @('-ModelKey', $modelKey, '-Backend', $backendKey, '-Context', "$contextSize")
if ($useVision) { $serveArguments += '-Vision' }
if ($useMtp) { $serveArguments += '-Mtp' }

$powerShellHost = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$serverLogPath = Join-Path $root 'llama-server.log'
$serverErrorLogPath = Join-Path $root 'llama-server.err.log'

if ($onWindows) {
  # -NoExit keeps the console window up after the server stops, so whatever it
  # printed on the way out is still readable. Start-Process joins ArgumentList
  # into one command line that is then parsed again, so the script path carries
  # its own quotes in case the folder has a space in it.
  $serverArgs = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit',
    '-File', ('"' + $serveScript + '"')
  ) + $serveArguments
  Start-Process -FilePath $powerShellHost -ArgumentList $serverArgs `
    -WorkingDirectory $root -WindowStyle Normal | Out-Null
} else {
  # macOS has no equivalent of "start this in its own console window" short of
  # driving Terminal through AppleScript, which raises a permission prompt the
  # user can refuse. The server is detached instead and its output goes to a log.
  #
  # The redirection deliberately does NOT use Start-Process -RedirectStandardOutput.
  # On Unix that option pumps the child's output to the file from inside THIS
  # process, so it stops the moment the launcher exits, which it does right
  # after printing the summary below. Measured: with the parent kept alive the
  # log fills normally, with the parent gone it stays at 0 bytes, and nothing
  # anywhere reports an error. Handing the redirection to sh instead gives the
  # child those file descriptors directly, so the log does not depend on this
  # process still being around. nohup is what makes it survive the terminal
  # that started it closing.
  $quoted = @($powerShellHost, '-NoProfile', '-File', $serveScript) + $serveArguments |
    ForEach-Object { ConvertTo-ShellQuoted $_ }
  $command = 'nohup ' + ($quoted -join ' ') +
    ' > ' + (ConvertTo-ShellQuoted $serverLogPath) +
    ' 2> ' + (ConvertTo-ShellQuoted $serverErrorLogPath) + ' < /dev/null &'
  # The call operator passes argv straight through on Unix. Start-Process would
  # join and re-parse it, splitting this command on its spaces.
  & '/bin/sh' '-c' $command
}

Write-Host ''
Write-Host '  Loading the model...' -ForegroundColor Cyan
$ready = $false
for ($attempt = 0; $attempt -lt 300; $attempt++) {
  try {
    if ((Invoke-RestMethod -Uri "$apiRoot/health" -TimeoutSec 2).status -eq 'ok') { $ready = $true; break }
  } catch {}
  Start-Sleep -Seconds 1
}
if (-not $ready) {
  $where = if ($onWindows) { 'Check the server window.' } else { "Check $serverErrorLogPath" }
  throw "llama.cpp was not ready within 300 seconds. $where"
}

# Whatever the estimate said, Windows has the final word. Ask it directly
# rather than leaving a silent slowdown for the user to discover.
#
# There is no macOS counterpart, and inventing one would be worse than having
# none: the counter measures VRAM that spilled into system RAM, and on unified
# memory there is nowhere for it to spill from. When Metal runs out here the
# symptom is the machine swapping, not a quiet migration nothing reports.
$spilledMiB = 0
if ($onWindows) {
  try {
    $server = Get-Process llama-server -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($server) {
      $samples = (Get-Counter '\GPU Process Memory(*)\Shared Usage' -ErrorAction Stop).CounterSamples |
        Where-Object { $_.InstanceName -like "*pid_$($server.Id)*" }
      $spilledMiB = [math]::Round((($samples | Measure-Object CookedValue -Sum).Sum) / 1MB)
    }
  } catch {}
}

# ------------------------------------------------------------------ summary

Write-Host ''
Write-Host "  $('=' * 62)" -ForegroundColor Green
Write-Host '  SERVER RUNNING' -ForegroundColor Green
Write-Host "  $('=' * 62)" -ForegroundColor Green
Write-Host "  Model     : $($model.alias)  ($(if ($useVision) { 'with vision' } else { 'no vision' }))"
Write-Host "  Backend   : $backendKey  -  $budgetLabel"
Write-Host "  Context   : $($contextSize / 1024)K   (KV $cacheType, $(Format-MiB $contextEntry.KvMiB))"
$finalMiB = $contextEntry.TotalMiB + $(if ($useMtp) { $mtpCostMiB } else { 0 })
Write-Host "  MTP       : $(if ($useMtp) { "enabled (+$(Format-MiB $mtpCostMiB))" } else { 'disabled' })"
Write-Host "  Estimated : $(Format-MiB $finalMiB) of $(Format-MiB $budgetMiB) usable"
Write-Host "  API       : $apiBase"
Write-Host "  Chat UI   : $apiRoot  (built into llama.cpp, always available)"
if ($onWindows) {
  Write-Host '  The server stays in its own window. Leave it open.' -ForegroundColor DarkGray
} else {
  Write-Host "  Log       : $serverLogPath" -ForegroundColor DarkGray
  Write-Host '  The server is detached and outlives this terminal. Follow it with:' -ForegroundColor DarkGray
  Write-Host "    tail -f `"$serverLogPath`"" -ForegroundColor DarkGray
}
if ($spilledMiB -gt 64) {
  Write-Host ''
  Write-Host "  WARNING: $(Format-MiB $spilledMiB) of this is in shared memory, not on the card." -ForegroundColor Yellow
  Write-Host '  Windows paged it into system RAM. Generation will be far slower than it should be.' -ForegroundColor Yellow
  Write-Host '  Free the GPU, or re-run and pick a smaller context or the no-vision variant.' -ForegroundColor Yellow
}

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
if ($onWindows) {
  Write-Host '    Get-Process llama-server | Stop-Process -Force' -ForegroundColor DarkGray
} else {
  # -x matches the process name exactly. Without it, -f would also match this
  # launcher's own command line and any editor that happens to have the string
  # open, which is a bad habit to print in a summary people copy from.
  Write-Host '    pkill -x llama-server' -ForegroundColor DarkGray
}
Write-Host ''
