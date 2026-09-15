# The arithmetic the fit table is made of, and the catalog reasoning around it.
# Split out of llmfit.ps1 so the web panel in lib/ui.ps1 shows the same numbers
# as the terminal launcher rather than its own: a second implementation would
# drift, and a fit table nobody can trust is exactly what this project exists
# to replace.
#
# Nothing here prints. Every function takes what it needs and returns data, so
# the two front ends decide how to say it.

function Get-BackendDevices {
  param([string]$Folder, [string]$ToolsDirectory, [string]$ServerExe)
  $exe = Join-Path (Join-Path $ToolsDirectory $Folder) $ServerExe
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

function Get-LiveFreeByName {
  # Get-LiveFreeMiB answers 'how much is free on the busiest card', which is the
  # right question with one card and the wrong one when the launcher is about to
  # ask which of several to use. nvidia-smi will name them, and the name it
  # prints is character for character the one --list-devices prints, so the two
  # lists join on it. AMD and Intel ship no equivalent tool, and an integrated
  # GPU needs none: its memory is system RAM, which Get-SystemRamMiB already has.
  $map = @{}
  try {
    $raw = & nvidia-smi --query-gpu=name,memory.free --format=csv,noheader,nounits 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return $map }
    foreach ($line in @($raw)) {
      $parts = "$line".Split(',')
      if ($parts.Count -lt 2) { continue }
      $free = 0.0
      if ([double]::TryParse($parts[1].Trim(), [ref]$free)) { $map[$parts[0].Trim()] = $free }
    }
  } catch {}
  return $map
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
  # The DEFAULT KV cache type: global by default and overridable per model,
  # because what it costs is not a property of the launcher. Quantizing it was
  # measured on CUDA to move attention off the GPU and collapse prompt
  # processing from 3355 to 40 tokens per second, so a model that wants a
  # quantized cache usually wants it on one platform and not the other.
  # Read-CacheType below turns this into the pre-selected entry of a menu; what
  # actually loads is whatever comes back from there.
  param($Model, $ServerConfig, [string]$Platform)
  $type = Get-PlatformSetting -Block $Model.cache -Platform $Platform -Name 'type'
  if ($type) { return @{ Type = $type; Source = "config/models.json ($($Model.alias))" } }
  return @{ Type = $ServerConfig.cacheType; Source = 'config/server.json' }
}

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

function Format-MiB {
  param([double]$MiB)
  if ($MiB -ge 1024) { return ('{0:N1} GiB' -f ($MiB / 1024)) }
  return ('{0:N0} MiB' -f $MiB)
}

function Get-ModelOverhead {
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
  #
  # Returns the figure AND whether it was measured, because a caller that shows
  # one without the other is presenting a guess as a measurement.
  param($Model, $ServerConfig, [string]$Platform, [bool]$OnWindows, [bool]$UseVision)

  $overheadBlock = $Model.overhead
  $calibrated = $true
  if (-not $overheadBlock) {
    # A model nobody has measured at all, on any platform. It still runs; the
    # estimate just inherits constants fitted to a different model.
    $calibrated = $false
  } elseif (-not $OnWindows) {
    $platformBlock = $null
    if ($overheadBlock.Contains($Platform)) { $platformBlock = $overheadBlock[$Platform] }
    if ($platformBlock) { $overheadBlock = $platformBlock } else { $calibrated = $false }
  }
  # A block that carries only platform sub-blocks has no top-level baseMiB, and on
  # Windows the branch above never looks inside one. Without this the constants
  # from server.json would stand in silently, which is the one thing the warning
  # around this exists to prevent.
  if ($overheadBlock -and $null -eq $overheadBlock.baseMiB) { $calibrated = $false }

  $miB = if ($overheadBlock -and $null -ne $overheadBlock.baseMiB) { [double]$overheadBlock.baseMiB }
         else { [double]$ServerConfig.computeOverheadMiB }
  if ($UseVision) {
    $miB += if ($overheadBlock -and $null -ne $overheadBlock.visionMiB) { [double]$overheadBlock.visionMiB }
            else { [double]$ServerConfig.visionOverheadMiB }
  }
  return @{
    MiB = $miB
    Calibrated = $calibrated
    # What the warning has to say, since 'nobody measured this model anywhere'
    # and 'nobody measured it HERE' are different problems with the same effect.
    Missing = if ($Model.overhead) { 'measured on this platform' } else { 'measured for this model' }
  }
}

function Get-FitTable {
  # One row per context length the catalog offers, with the two verdicts the
  # launcher colours and the panel paints: Fits is the comfortable 92% of the
  # budget, Tight is everything up to the budget itself.
  param(
    $Model, $ServerConfig, [double]$BudgetMiB, [double]$WeightsMiB,
    [double]$VisionMiB, [double]$CacheBytes, [double]$OverheadMiB
  )
  $rows = @()
  foreach ($context in $ServerConfig.contextOptions) {
    if ($context -gt $Model.geometry.maxContext) { continue }
    $kvMiB = Get-KvMiB -Geometry $Model.geometry -Context $context -BytesPerElement $CacheBytes
    $totalMiB = $WeightsMiB + $VisionMiB + $kvMiB + $OverheadMiB
    $rows += [pscustomobject]@{
      Context = $context; KvMiB = $kvMiB; TotalMiB = $totalMiB
      Fits = ($totalMiB -le ($BudgetMiB * 0.92)); Tight = ($totalMiB -le $BudgetMiB)
    }
  }
  return @($rows)
}

# Whether speculation pays off is a property of the backend, measured per
# backend and declared in config/backends.json rather than inferred from its
# name: on Vulkan the cost of maintaining the draft context cancels out the
# gain. And only if the model can draft at all, which happens two ways: an
# 'mtp' block means real draft weights, a 'speculative' block means a
# model-free method such as ngram that predicts from the context window.
# What it costs is measured per model and differs by an order of magnitude:
# an embedded draft context is built against the whole model, a companion draft
# file is small, and a model-free method costs nothing whatsoever. Counting a
# real cost as free is how a configuration that reports FITS ends up spilling
# into system RAM.
#
# Every setting below can be overridden per platform, because none of them
# turned out to travel: the same model's embedded MTP costs 1200 MiB on CUDA
# and 817 on Metal, and is worth enabling on one and not the other.
#
# A model-free method wins over draft weights when a model declares both, which
# is the order serve.ps1 resolves in too. No model here declares both today.
#
# The block has to follow the resolved method rather than be picked separately,
# or the two can disagree: a model carrying an mtp block plus a speculative
# block with no specType in it would resolve draft-mtp - real draft weights,
# 1200 MiB on CUDA - while drawing its cost from the speculative block and
# reporting 0. The memory check below would then be skipped on exactly the
# configuration it exists to catch.

function Get-SpecPlan {
  # The decision and the sentence that explains it. Every branch is a refusal
  # with a reason: the catalog turning it off, the backend not having it, a
  # measured context ceiling, or the memory simply not being there.
  param(
    $Model, $Backend, [string]$BackendKey, [string]$Platform, [double]$BudgetMiB,
    [double]$TotalMiB, [int]$ContextSize
  )

  $specType = Get-PlatformSetting -Block $Model.speculative -Platform $Platform -Name 'specType'
  if ($specType) {
    $specBlock = $Model.speculative
  } elseif ($Model.mtp) {
    $specType = 'draft-mtp'
    $specBlock = $Model.mtp
  } else {
    $specType = 'none'
    $specBlock = $null
  }

  $costRaw = Get-PlatformSetting -Block $specBlock -Platform $Platform -Name 'costMiB'
  # Compared against $null rather than tested for truth, because 0 is a real
  # answer here: a model-free method loads no weights, and reading that as
  # "unset" would charge it the 512 MiB fallback meant for a block that forgot.
  $costMiB = if ($null -ne $costRaw) { [double]$costRaw } else { 512 }
  $autoEnable = Get-PlatformSetting -Block $specBlock -Platform $Platform -Name 'autoEnable'
  $maxContext = Get-PlatformSetting -Block $specBlock -Platform $Platform -Name 'maxContext'
  $note = Get-PlatformSetting -Block $specBlock -Platform $Platform -Name 'note'
  # The +256 is margin around a measured weight cost. A method that loads nothing
  # has no cost to be wrong about, so it reserves nothing and the memory branch
  # below is skipped for it entirely - there is no shortage it could relieve.
  $headroomMiB = if ($costMiB -gt 0) { $costMiB + 256 } else { 0 }

  $use = $false
  if (-not $specBlock) {
    $reason = 'this model ships no MTP layers and declares no model-free method'
  } elseif ($autoEnable -eq $false) {
    $reason = 'turned off for this model in config/models.json'
  } elseif ($Backend.speculativeDecoding -ne $true) {
    $reason = "not enabled for the $BackendKey backend in config/backends.json"
  } elseif ($maxContext -and $ContextSize -gt [int]$maxContext) {
    # A ceiling that was measured, not derived. costMiB is modelled as a flat
    # number, but an embedded draft context carries its own KV cache and so grows
    # with the context length: the memory check below would wave through a
    # configuration that loads, reports healthy, and then dies on its first
    # decode. Until the cost is modelled per token, the honest bound is the
    # longest context somebody actually ran.
    $reason = "only verified up to $([int]$maxContext / 1024)K on $Platform and you picked $($ContextSize / 1024)K"
  } elseif ($headroomMiB -gt 0 -and ($BudgetMiB - $TotalMiB) -lt $headroomMiB) {
    $margin = $BudgetMiB - $TotalMiB
    $reason = if ($margin -lt 0) {
      "this configuration already exceeds the budget by $(Format-MiB ([math]::Abs($margin)))"
    } else {
      "it costs $(Format-MiB $costMiB) and only $(Format-MiB $margin) is left over"
    }
  } else {
    $use = $true
    $reason = if ($costMiB -gt 0) {
      "$specType costs $(Format-MiB $costMiB), leaving $(Format-MiB ($BudgetMiB - $TotalMiB - $costMiB)) free"
    } else {
      "$specType loads no weights, so it costs no memory at all"
    }
  }
  return [pscustomobject]@{
    Use = $use; Type = $specType; CostMiB = $costMiB; Reason = $reason; Note = $note
    Block = $specBlock; MaxContext = $maxContext
  }
}
