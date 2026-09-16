param(
  [Alias('h')]
  [switch]$Help
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$modelsDirectory = Join-Path $root 'models'
$toolsDirectory = Join-Path $root 'tools'

# ------------------------------------------------------------------ platform

# $IsWindows, $IsMacOS and $IsLinux are PowerShell 7 automatic variables.
# Windows PowerShell 5.1 does not define them at all, and that absence is itself
# the answer: 5.1 only ever runs on Windows. They cannot be assigned to, because
# PowerShell 7 makes them read-only, hence the separate names.
$onWindows = if ($null -ne $IsWindows) { [bool]$IsWindows } else { $true }
$onMacOS = if ($null -ne $IsMacOS) { [bool]$IsMacOS } else { $false }
$onLinux = if ($null -ne $IsLinux) { [bool]$IsLinux } else { $false }
$platform = if ($onMacOS) { 'macos' } elseif ($onLinux) { 'linux' } else { 'windows' }
# Linux is the one platform shipped here for two architectures, so 'which
# platform' stopped being enough to decide what can run. The .NET value is used
# rather than uname because it is the same answer on every host and needs no
# process. x64 and Arm64 are what it returns for the two that matter.
$architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
$exeSuffix = if ($onWindows) { '.exe' } else { '' }
$serverExe = "llama-server$exeSuffix"
# On Windows the bundled curl is curl.exe; invoking it unqualified would find
# the PowerShell alias for Invoke-WebRequest instead, which takes none of these
# flags. On macOS there is no such alias and the binary is plain curl.
$curlCommand = if ($onWindows) { 'curl.exe' } else { 'curl' }

# ----------------------------------------------------------------- libraries

# What used to be defined here. The web panel needs the same arithmetic and the
# same downloader, and two implementations of either is how the two front ends
# start disagreeing about what fits. lib/fit.ps1 computes and returns; nothing
# in it prints, so each front end decides how to say it.
. (Join-Path $root (Join-Path 'lib' 'config.ps1'))
. (Join-Path $root (Join-Path 'lib' 'fit.ps1'))
. (Join-Path $root (Join-Path 'lib' 'artifacts.ps1'))

# ------------------------------------------------------------------- helpers

function Write-Utf8NoBom {
  param([string]$Path, [string]$Content)
  [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
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

# --------------------------------------------------------- device detection

function ConvertTo-ShellQuoted {
  # Single quotes are the only construct sh does not interpret anything inside,
  # so wrapping in them and closing-escaping-reopening around any embedded
  # quote makes a path safe whatever it contains. Needed because the macOS
  # server launch goes through sh -c; see the comment where it is built.
  param([string]$Value)
  return "'" + $Value.Replace("'", "'\''") + "'"
}

function Get-CacheNote {
  # One sentence per type, and it has to be platform-aware. The collapse a
  # quantized KV cache causes was measured on CUDA, where flash attention has
  # no kernel for one and silently moves attention to the CPU. It has not been
  # measured on Metal, so it is not asserted there - saying "this will be slow"
  # on a platform nobody tested would be inventing a measurement. On Linux it
  # HAS been measured, on Vulkan and one iGPU: Gemma 4 E4B, llama-bench, f16
  # gives pp512 353.3 and tg128 31.9, q8_0 gives 329.3 and 31.0. The hole CUDA
  # has is not there, so the note says the size of the real cost instead.
  param([string]$Type)
  if ($Type -like 'f*' -or $Type -like 'bf*') { return 'full precision, attention stays on the GPU' }
  if ($onMacOS) { return 'QUANTIZED: costs prompt speed on CUDA; unmeasured on Metal' }
  if ($onLinux) { return 'QUANTIZED: collapses prompt on CUDA; 7% on Vulkan/gfx1103' }
  return 'QUANTIZED: attention falls back to the CPU on CUDA'
}

function Get-CacheColor {
  param([string]$Type)
  if ($Type -like 'f*' -or $Type -like 'bf*') { return 'Green' }
  return 'Yellow'
}

function Read-CacheType {
  # The KV type is asked, not assumed, and it is asked BEFORE the fit table
  # because the fit table is sized with it: the same 27B at 32K is 2.0 GiB of
  # cache in f16 and 1.1 in q8_0, and a table drawn with one number while the
  # server loads the other describes a run nobody performed.
  #
  # config/server.json still decides what is pre-selected, so pressing Enter
  # reproduces the behaviour this launcher had before the menu existed. What
  # the menu adds is the ability to measure the trade yourself on your own
  # hardware, which is the only way anyone is going to find out whether the
  # CUDA collapse also exists on Metal.
  param($ServerConfig, $Default)

  $options = @($ServerConfig.cacheTypeOptions)
  # No menu declared, or a default that is not in it: fall back rather than
  # hide the type the catalog asked for behind a list that does not contain it.
  if (-not $options -or $options.Count -eq 0) { return $Default }
  if ($options -notcontains $Default.Type) { $options = @($Default.Type) + $options }

  Write-Host '  KV cache type. The fit table below is sized with what you pick here.' -ForegroundColor DarkGray
  $defaultIndex = 1
  for ($i = 0; $i -lt $options.Count; $i++) {
    $type = $options[$i]
    $bytes = $ServerConfig.cacheTypeBytes[$type]
    if (-not $bytes) {
      throw "config/server.json offers '$type' in cacheTypeOptions but declares no cacheTypeBytes for it."
    }
    if ($type -eq $Default.Type) { $defaultIndex = $i + 1 }
    Write-Host ("  {0,2}) {1,-5} {2,-7} bytes/element   " -f ($i + 1), $type, $bytes) -NoNewline
    Write-Host (Get-CacheNote -Type $type) -ForegroundColor (Get-CacheColor -Type $type) -NoNewline
    if ($type -eq $Default.Type) { Write-Host "   (default, from $($Default.Source))" -ForegroundColor DarkGray }
    else { Write-Host '' }
  }

  $choice = Read-Choice -Prompt 'KV cache' -Maximum $options.Count -Default $defaultIndex
  $picked = $options[$choice - 1]
  $source = if ($picked -eq $Default.Type) { $Default.Source } else { 'your choice at launch' }
  return @{ Type = $picked; Source = $source }
}

function Get-SystemRamMiB {
  # Win32_ComputerSystem is a WMI class and does not exist off Windows; the
  # macOS answer comes from sysctl, which is always present. Linux has no
  # sysctl for it and /proc/meminfo is the canonical source - MemTotal is
  # already in KiB, and it is what free(1) itself reads.
  try {
    if ($onWindows) {
      return [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1MB)
    }
    if ($onLinux) {
      $line = (Get-Content -LiteralPath '/proc/meminfo' -TotalCount 1)
      if ("$line" -match '^MemTotal:\s+(\d+)\s+kB') { return [math]::Round([double]$matches[1] / 1024) }
      return 0
    }
    $bytes = [double](& sysctl -n hw.memsize)
    if ($bytes -gt 0) { return [math]::Round($bytes / 1MB) }
  } catch {}
  return 0
}

# ---------------------------------------------------------- fit calculation

# --------------------------------------------------------------------- start

$catalog = Read-JsonConfig -Name 'models.json' -Root $root
$backends = Read-JsonConfig -Name 'backends.json' -Root $root
$serverConfig = Read-JsonConfig -Name 'server.json' -Root $root

. (Join-Path $root (Join-Path 'lib' 'net.ps1'))
# config/server.json holds the address llama-server BINDS to, and the useful
# value there is 0.0.0.0 - every interface, which is what makes the server
# reachable from the rest of the house. It is not an address anything can
# connect to: Windows refuses it and the other two only fall through to the
# loopback by accident. Everything this launcher and the harnesses talk to
# therefore goes to $apiRoot below, and the addresses other machines use are
# carried separately on $endpoint. See lib/net.ps1.
$endpoint = Get-ServerEndpoint -ServerConfig $serverConfig -OnWindows $onWindows -OnMacOS $onMacOS -OnLinux $onLinux
$apiRoot = $endpoint.LocalRoot
$apiBase = "$apiRoot/v1"
# Keys starting with '_' are documentation inside the catalog, not models.
$modelKeys = @($catalog.Keys | Where-Object { -not $_.StartsWith('_') })
# Only the backends that can run here. A CUDA zip is not something a Mac should
# be offered and then fail to execute, and neither is an x64 build on an
# aarch64 board. A backend without an architecture runs on the only one its
# platform has.
$backendKeys = @($backends.Keys | Where-Object {
  -not $_.StartsWith('_') -and $backends[$_].platform -eq $platform -and
  ((-not $backends[$_].architecture) -or $backends[$_].architecture -eq $architecture)
})
if (-not $backendKeys.Count) {
  throw "config/backends.json declares no backend for platform '$platform' on $architecture."
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

# Read once and use twice: in the backend list below, and again when a backend
# that enumerates several devices asks which one to pin.
$liveFree = Get-LiveFreeByName

$options = @()
foreach ($key in $backendKeys) {
  $backend = $backends[$key]
  $installed = Test-Path -LiteralPath (Join-Path (Join-Path $toolsDirectory $backend.folder) $serverExe)
  $devices = @(if ($installed) { Get-BackendDevices -Folder $backend.folder -ToolsDirectory $toolsDirectory -ServerExe $serverExe } else { @() })
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
  if ($options[$i].Devices.Count -and $recommended -eq 1 -and $options[$i].Key -notlike 'cpu*') { $recommended = $i + 1 }
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
      Write-Host ("       {0,-8} {1,-28} {2,10} {3}, {4,10} usable" -f $device.Id, $device.Name, (Format-MiB $device.TotalMiB), $totalLabel, (Format-MiB ($device.TotalMiB - $deviceReserveMiB))) -NoNewline -ForegroundColor DarkGray
      # The 'free' in the line above came from --list-devices and is static: it
      # reports the same figure on an idle card and on one with 15 GB in use.
      # Where a live reading exists, say so here rather than let someone pick a
      # device on a number that was never true.
      if ($liveFree.ContainsKey($device.Name)) {
        Write-Host (", {0} free now" -f (Format-MiB $liveFree[$device.Name])) -ForegroundColor $(if ($liveFree[$device.Name] -lt ($device.TotalMiB / 2)) { 'Yellow' } else { 'DarkGray' })
      } else {
        Write-Host ''
      }
    }
  } elseif ($option.Key -like 'cpu*') {
    Write-Host ("       no GPU: uses system RAM, {0} nominally free" -f (Format-MiB $systemRamMiB)) -ForegroundColor DarkGray
  } else {
    Write-Host '       no devices detected' -ForegroundColor DarkGray
  }
}

$choice = Read-Choice -Prompt 'Architecture' -Maximum $options.Count -Default $recommended
$selected = $options[$choice - 1]
$backendKey = $selected.Key
$backend = $selected.Backend
Ensure-Backend -Backend $backend -ToolsDirectory $toolsDirectory `
  -DownloadsDirectory (Join-Path $root 'downloads') -ServerExe $serverExe -CurlCommand $curlCommand
if (-not $selected.Devices.Count -and $backendKey -notlike 'cpu*') {
  $selected.Devices = @(Get-BackendDevices -Folder $backend.folder -ToolsDirectory $toolsDirectory -ServerExe $serverExe)
  if ($selected.Devices.Count) { $selected.BudgetMiB = ($selected.Devices | Measure-Object -Property TotalMiB -Maximum).Maximum - $deviceReserveMiB }
}
# --------------------------------------------------------------- 1b. DEVICE

# A backend enumerates every device its API can reach, and llama.cpp's default
# split mode is 'layer' across all of them. On a machine with an APU and a
# discrete card that puts part of the model on a card nobody chose - sized with
# the static 'free' from --list-devices. Measured here: a Vulkan build reported
# 15227 MiB free on an RTX 5070 Ti while nvidia-smi reported 798, because a
# training job held the rest. Pinning is also what makes the fit table honest,
# since it is computed against ONE device's memory and so one device has to run
# it. Backends declare whether they need this; see config/backends.json.
$deviceId = $null
$chosenDevice = $null
if ($backend.pinDevice -and $selected.Devices.Count) {
  $ranked = @($selected.Devices | Sort-Object TotalMiB -Descending)
  $deviceChoice = 1
  if ($ranked.Count -gt 1) {
    Write-Host ''
    Write-Host '  This backend can see more than one device, and llama.cpp would spread the' -ForegroundColor DarkGray
    Write-Host '  model over all of them. Pick the one that should carry it.' -ForegroundColor DarkGray
    for ($i = 0; $i -lt $ranked.Count; $i++) {
      $device = $ranked[$i]
      $mark = if ($i -eq 0) { ' [recommended]' } else { '' }
      Write-Host ("  {0,2}) {1,-8} {2,-28} {3,10} total{4}" -f ($i + 1), $device.Id, $device.Name, (Format-MiB $device.TotalMiB), $mark)
      if ($liveFree.ContainsKey($device.Name)) {
        Write-Host ("       {0} free right now against the {1} this backend reports" -f (Format-MiB $liveFree[$device.Name]), (Format-MiB $device.FreeMiB)) -ForegroundColor $(if ($liveFree[$device.Name] -lt ($device.TotalMiB / 2)) { 'Yellow' } else { 'DarkGray' })
      }
    }
    $deviceChoice = Read-Choice -Prompt 'Device' -Maximum $ranked.Count -Default 1
  }
  $chosenDevice = $ranked[$deviceChoice - 1]
  $deviceId = $chosenDevice.Id
  $selected.BudgetMiB = $chosenDevice.TotalMiB - $deviceReserveMiB
}

$budgetMiB = $selected.BudgetMiB
$budgetSource = if ($onMacOS) { 'what macOS recommends one process keep resident' }
                else { 'total minus driver reserve' }
# With a device pinned the budget belongs to THAT device. Without one the model
# is spread over everything, and the largest card is the closest thing to a
# single number for a split this launcher does not control.
$best = if ($chosenDevice) { $chosenDevice }
        elseif ($selected.Devices.Count) { $selected.Devices | Sort-Object TotalMiB -Descending | Select-Object -First 1 }
        else { $null }
if ($best -and $best.Name -match 'NVIDIA') {
  # Prefer the reading for THIS card; Get-LiveFreeMiB reports the emptiest one,
  # which is the wrong card as soon as there is more than one.
  $live = if ($liveFree.ContainsKey($best.Name)) { $liveFree[$best.Name] } else { Get-LiveFreeMiB }
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
      # The encoder falls back to the catalog's declared size the same way the
      # weights line does. Printing "vision 0 MiB" for a file that has not been
      # downloaded reads as "this one is free", which is the opposite of true.
      VisionMiB = if (-not $vision) { 0 }
                  elseif (Test-Path -LiteralPath (Join-Path $modelsDirectory $item.mmprojFile)) {
                    Get-FileMiB (Join-Path $modelsDirectory $item.mmprojFile)
                  } elseif ($item.mmprojBytes) { [double]$item.mmprojBytes / 1MB } else { 0 }
    }
  }
}

for ($i = 0; $i -lt $variants.Count; $i++) {
  $variant = $variants[$i]
  $visionText = if ($variant.Vision) { 'with vision' } else { 'no vision' }
  # Two ways a model can draft, and both are offered at step 4, so both belong
  # here. A model-free method names itself instead of claiming to be MTP, and it
  # is checked first because that is the order step 4 resolves in.
  $specText = if ($variant.Model.speculative) { "  $(Get-PlatformSetting -Block $variant.Model.speculative -Platform $platform -Name 'specType') available" }
    elseif ($variant.Model.mtp) { '  MTP available' }
    else { '' }
  $sizeText = if ($variant.WeightsMiB) {
    if ($variant.Vision) { "weights $(Format-MiB $variant.WeightsMiB) + vision $(Format-MiB $variant.VisionMiB)" }
    else { "weights $(Format-MiB $variant.WeightsMiB)" }
  } elseif ($variant.Model.modelBytes) {
    # The catalog knows the size before the file exists, so the menu says what
    # a choice will cost instead of only that it costs something.
    $declared = [double]$variant.Model.modelBytes / 1MB
    if ($variant.Vision -and $variant.Model.mmprojBytes) { $declared += [double]$variant.Model.mmprojBytes / 1MB }
    "$(Format-MiB $declared) to download"
  } else { 'will be downloaded' }
  Write-Host ("  {0,2}) {1,-28} {2,-11}" -f ($i + 1), $variant.Model.name, $visionText) -NoNewline
  Write-Host "  $sizeText$specText" -ForegroundColor DarkGray
}

$choice = Read-Choice -Prompt 'Model' -Maximum $variants.Count -Default 1
$variant = $variants[$choice - 1]
$modelKey = $variant.ModelKey
$model = $variant.Model
$useVision = $variant.Vision

Ensure-Artifact -Path (Join-Path $modelsDirectory $model.modelFile) -Url $model.modelUrl -Sha256 $model.modelSha256 -CurlCommand $curlCommand
if ($useVision) {
  Ensure-Artifact -Path (Join-Path $modelsDirectory $model.mmprojFile) -Url $model.mmprojUrl -Sha256 $model.mmprojSha256 -CurlCommand $curlCommand
}
$weightsMiB = Get-FileMiB (Join-Path $modelsDirectory $model.modelFile)
$visionMiB = if ($useVision) { Get-FileMiB (Join-Path $modelsDirectory $model.mmprojFile) } else { 0 }

# -------------------------------------------------------------- 3. CONTEXT

Write-Step 3 'KV CACHE AND CONTEXT'
$cacheDefault = Get-CacheType -Model $model -ServerConfig $serverConfig -Platform $platform
$cacheChoice = Read-CacheType -ServerConfig $serverConfig -Default $cacheDefault
$cacheType = $cacheChoice.Type
$cacheBytes = [double]$serverConfig.cacheTypeBytes[$cacheType]
if (-not $cacheBytes) {
  throw "Unknown KV cache type '$cacheType' from $($cacheChoice.Source). Declared types: $(@($serverConfig.cacheTypeBytes.Keys) -join ', ')"
}
Write-Host ''
Write-Host "  KV cache in $cacheType, $cacheBytes bytes per element ($(Get-CacheNote -Type $cacheType))." -ForegroundColor DarkGray
if ($cacheChoice.Source -eq 'your choice at launch') {
  # Say what you overrode. Picking a type once and forgetting the catalog
  # recommended another one is how a slow run gets blamed on the model.
  Write-Host "  You picked that. The default here is $($cacheDefault.Type), from $($cacheDefault.Source)." -ForegroundColor DarkGray
} elseif ($cacheChoice.Source -ne 'config/server.json') {
  Write-Host "  That type is set for this model in $($cacheChoice.Source), not globally." -ForegroundColor DarkGray
}
Write-Host "  $($model.geometry.summary)." -ForegroundColor DarkGray
Write-Host ''

# Both numbers and whether they were measured come from lib/fit.ps1, so the
# panel cannot quietly show a different total than the one printed here.
$overhead = Get-ModelOverhead -Model $model -ServerConfig $serverConfig -Platform $platform `
  -OnWindows $onWindows -UseVision $useVision
$overheadMiB = $overhead.MiB
if (-not $overhead.Calibrated) {
  Write-Host "  NOTE: no overhead $($overhead.Missing) yet, so constants fitted to something" -ForegroundColor Yellow
  Write-Host '  else are standing in. The KV column is exact; the estimated total is a guess' -ForegroundColor Yellow
  Write-Host "  until someone measures it here and writes it into models.json." -ForegroundColor Yellow
  Write-Host ''
}
$contexts = @(Get-FitTable -Model $model -ServerConfig $serverConfig -BudgetMiB $budgetMiB `
  -WeightsMiB $weightsMiB -VisionMiB $visionMiB -CacheBytes $cacheBytes -OverheadMiB $overheadMiB `
  -Platform $platform -SystemRamMiB $systemRamMiB)

$defaultContext = 1
$anyOffload = $false
for ($i = 0; $i -lt $contexts.Count; $i++) {
  $entry = $contexts[$i]
  $status = if ($entry.Fits) { 'FITS' } elseif ($entry.Tight) { 'TIGHT' } else { 'TOO BIG' }
  $color = if ($entry.Fits) { 'Green' } elseif ($entry.Tight) { 'Yellow' } else { 'Red' }
  # The default lands on the longest context that needs NOTHING moved off the
  # card. A row that only gets there with experts in system RAM is a trade, and
  # a trade is something to pick on purpose rather than to inherit by pressing
  # Enter on a table you skimmed.
  if ($entry.Fits -and -not $entry.CpuMoeN) { $defaultContext = $i + 1 }
  Write-Host ("  {0,2}) {1,5}   KV {2,10}   estimated total {3,10}   " -f ($i + 1), "$($entry.Context / 1024)K", (Format-MiB $entry.KvMiB), (Format-MiB $entry.TotalMiB)) -NoNewline
  Write-Host $status -ForegroundColor $color -NoNewline
  if ($entry.CpuMoeN) {
    $anyOffload = $true
    Write-Host "   experts of $($entry.CpuMoeN) layers in system RAM, $(Format-MiB $entry.OffloadMiB) off the card" -ForegroundColor DarkCyan
  } else {
    Write-Host ''
  }
}
if ($anyOffload) {
  Write-Host ''
  Write-Host '  A row with a cyan note reaches that context only because some expert layers' -ForegroundColor DarkGray
  Write-Host '  stop living on the card. The total shown is what stays in VRAM; the rest is' -ForegroundColor DarkGray
  Write-Host '  read from system RAM by the CPU. Only a fraction of the experts run per token,' -ForegroundColor DarkGray
  Write-Host '  so the cost is expected to be small - and NOBODY HERE HAS MEASURED IT. Compare' -ForegroundColor DarkGray
  Write-Host '  tokens per second against a row that needs none before trusting the trade.' -ForegroundColor DarkGray
}

$choice = Read-Choice -Prompt 'Context' -Maximum $contexts.Count -Default $defaultContext
$contextEntry = $contexts[$choice - 1]
$contextSize = $contextEntry.Context
# Resolved from the row, never asked. The user picked a context; how many expert
# layers that costs is arithmetic, and arithmetic is this tool's job.
$nCpuMoe = [int]$contextEntry.CpuMoeN
if ($nCpuMoe -gt 0) {
  Write-Host ''
  Write-Host "  Experts of the first $nCpuMoe of $($model.geometry.expertOffload.expertLayers) layers go to system RAM, keeping $(Format-MiB $contextEntry.OffloadMiB) off the card." -ForegroundColor Cyan
  Write-Host "  Without that, $($contextSize / 1024)K would need $(Format-MiB $contextEntry.FullTotalMiB) against a budget of $(Format-MiB $budgetMiB)." -ForegroundColor DarkGray
}

# -------------------------------------------------- 4. SPECULATIVE DECODING

# Resolved in lib/fit.ps1 so the web panel refuses for the same reasons and in
# the same words. What comes back is the decision plus the sentence that
# explains it, which step 4 prints and the panel puts under the toggle.
$specPlan = Get-SpecPlan -Model $model -Backend $backend -BackendKey $backendKey -Platform $platform `
  -BudgetMiB $budgetMiB -TotalMiB $contextEntry.TotalMiB -ContextSize $contextSize
$specType = $specPlan.Type
$specCostMiB = $specPlan.CostMiB
$useSpec = $specPlan.Use
$specReason = $specPlan.Reason
$specNote = $specPlan.Note

Write-Step 4 'SPECULATIVE DECODING'
if ($useSpec) {
  Write-Host "  Enabled: $specReason" -ForegroundColor Green
  # What the catalog knows about this combination that the memory check cannot
  # express, such as it having been measured to buy nothing.
  if ($specNote) { Write-Host "  $specNote" -ForegroundColor Yellow }
  if ($specType -eq 'draft-mtp' -and $model.mtp.mode -eq 'draft-model') {
    Write-Host "  Draft model: $($model.mtp.file)" -ForegroundColor DarkGray
    Ensure-Artifact -Path (Join-Path $modelsDirectory $model.mtp.file) -Url $model.mtp.url -Sha256 $model.mtp.sha256 -CurlCommand $curlCommand
  }
} else {
  Write-Host "  Disabled: $specReason" -ForegroundColor DarkGray
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
# -CacheType is sent explicitly rather than left for serve.ps1 to resolve on its
# own. It would resolve the same default, but the fit table above was sized with
# whatever the menu returned, and a server that loads a different type turns that
# table into a description of a run nobody performed.
$serveArguments = @('-ModelKey', $modelKey, '-Backend', $backendKey, '-Context', "$contextSize", '-CacheType', $cacheType)
# Same invariant as -CacheType: the fit table was drawn with this number, so the
# server has to load with it too or the table described a different run.
if ($nCpuMoe -gt 0) { $serveArguments += @('-NCpuMoe', "$nCpuMoe") }
if ($deviceId) { $serveArguments += @('-Device', $deviceId) }
if ($useVision) { $serveArguments += '-Vision' }
if ($useSpec) { $serveArguments += '-Spec' }

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
$finalMiB = $contextEntry.TotalMiB + $(if ($useSpec) { $specCostMiB } else { 0 })
# Names the method, because 'enabled' next to a model with no draft weights
# reads as MTP to anyone who has used this launcher before.
$specSummary = if (-not $useSpec) { 'disabled' }
  elseif ($specCostMiB -gt 0) { "$specType (+$(Format-MiB $specCostMiB))" }
  else { "$specType (no memory cost)" }
Write-Host "  Spec dec  : $specSummary"
Write-Host "  Estimated : $(Format-MiB $finalMiB) of $(Format-MiB $budgetMiB) usable"
Write-Host "  API       : $apiBase"
Write-Host "  Chat UI   : $apiRoot  (built into llama.cpp, always available)"
# Where everyone else reaches it. The server has been listening on every
# interface all along; what was missing was anyone being told the address.
if (-not $endpoint.IsWildcard) {
  Write-Host "  LAN       : not reachable - bound to $($endpoint.BindHost) only." -ForegroundColor DarkGray
  Write-Host '              Set "host": "0.0.0.0" in config/server.json to open it to this network.' -ForegroundColor DarkGray
} elseif (-not $endpoint.LanAddresses.Count) {
  Write-Host '  LAN       : listening on every interface, but this machine has no network address right now.' -ForegroundColor DarkGray
} else {
  $lanRoot = $endpoint.LanRoots[0]
  Write-Host "  LAN       : $lanRoot  - same paths, from any device on this network" -ForegroundColor Cyan
  Write-Host "              API $lanRoot/v1" -ForegroundColor DarkGray
  if ($endpoint.MdnsRoot) {
    Write-Host "              or $($endpoint.MdnsRoot) wherever mDNS resolves" -ForegroundColor DarkGray
  }
  $otherAddresses = @($endpoint.LanAddresses | Select-Object -Skip 1)
  if ($otherAddresses.Count) {
    # A machine with Docker or a VPN listens on those too. Named, not hidden:
    # the first line is the one the routing table says the LAN would use, and
    # these are the rest of what a wildcard bind really opened.
    Write-Host ("              also listening on " + (($otherAddresses | ForEach-Object { "$($_.Address) ($($_.Interface))" }) -join ', ')) -ForegroundColor DarkGray
  }
  if ($onWindows) {
    Write-Host '              Windows Defender asks to allow this the first time; it has to be allowed on Private networks.' -ForegroundColor DarkGray
  }
}
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
