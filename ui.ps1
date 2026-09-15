param(
  # Overrides config/server.json for a one-off run; the config is the default.
  [int]$Port = 0,
  # Print the addresses and exit, for a launcher script that wants to know where
  # to point a browser without starting a second panel.
  [switch]$WhereIsIt
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$modelsDirectory = Join-Path $root 'models'
$toolsDirectory = Join-Path $root 'tools'
$uiDirectory = Join-Path $root 'ui'

# Windows PowerShell 5.1 defines none of them, and only ever runs on Windows. See llmfit.ps1.
$onWindows = if ($null -ne $IsWindows) { [bool]$IsWindows } else { $true }
$onMacOS = if ($null -ne $IsMacOS) { [bool]$IsMacOS } else { $false }
$onLinux = if ($null -ne $IsLinux) { [bool]$IsLinux } else { $false }
$platform = if ($onMacOS) { 'macos' } elseif ($onLinux) { 'linux' } else { 'windows' }
$architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
$serverExe = if ($onWindows) { 'llama-server.exe' } else { 'llama-server' }

. (Join-Path $root (Join-Path 'lib' 'config.ps1'))
. (Join-Path $root (Join-Path 'lib' 'fit.ps1'))
. (Join-Path $root (Join-Path 'lib' 'net.ps1'))

$catalog = Read-JsonConfig -Name 'models.json' -Root $root
$backends = Read-JsonConfig -Name 'backends.json' -Root $root
$serverConfig = Read-JsonConfig -Name 'server.json' -Root $root

$uiPort = if ($Port -gt 0) { $Port } elseif ($serverConfig.uiPort) { [int]$serverConfig.uiPort } else { 8089 }
$modelKeys = @($catalog.Keys | Where-Object { -not $_.StartsWith('_') })
$backendKeys = @($backends.Keys | Where-Object {
  -not $_.StartsWith('_') -and $backends[$_].platform -eq $platform -and
  ((-not $backends[$_].architecture) -or $backends[$_].architecture -eq $architecture)
})

$platformConfig = $serverConfig.platforms[$platform]
$deviceReserveMiB = [double]$platformConfig.deviceReserveMiB
$safetyMarginPercent = [double]$platformConfig.safetyMarginPercent

$endpoint = Get-ServerEndpoint -ServerConfig $serverConfig -OnWindows $onWindows -OnMacOS $onMacOS -OnLinux $onLinux
$panelRoots = @("http://127.0.0.1:$uiPort") + @($endpoint.LanAddresses | ForEach-Object { "http://$($_.Address):$uiPort" })

if ($WhereIsIt) {
  $panelRoots | ForEach-Object { Write-Output $_ }
  exit 0
}

$progressPath = Join-Path $root '.llmfit-ui-progress.json'
$statePath = Join-Path $root '.llmfit-ui-state.json'

# ------------------------------------------------------------------ helpers

function Get-BudgetForBackend {
  # The same three-step budget the launcher computes at step 1: the largest
  # device the backend enumerates, minus the driver reserve, minus the platform
  # safety margin. With no device at all it is system RAM, because that is what
  # a CPU backend actually runs in.
  param([string]$Key)
  $backend = $backends[$Key]
  $installed = Test-Path -LiteralPath (Join-Path (Join-Path $toolsDirectory $backend.folder) $serverExe)
  $devices = @(if ($installed) { Get-BackendDevices -Folder $backend.folder -ToolsDirectory $toolsDirectory -ServerExe $serverExe } else { @() })
  $systemRamMiB = Get-SystemRamMiB
  $best = if ($devices.Count) { $devices | Sort-Object TotalMiB -Descending | Select-Object -First 1 } else { $null }
  $budget = if ($best) { $best.TotalMiB - $deviceReserveMiB } else { $systemRamMiB }
  $held = 0
  if ($best -and $safetyMarginPercent -gt 0) {
    $held = [math]::Round($best.TotalMiB * $safetyMarginPercent / 100)
    $budget = $budget - $held
  }
  return [pscustomobject]@{
    Key = $Key; Name = $backend.name; Installed = $installed
    Devices = @($devices | ForEach-Object { @{ id = $_.Id; name = $_.Name; totalMiB = $_.TotalMiB } })
    BudgetMiB = $budget; HeldBackMiB = $held; SystemRamMiB = $systemRamMiB
    Speculative = [bool]$backend.speculativeDecoding
  }
}

function Get-SystemRamMiB {
  try {
    if ($onWindows) { return [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1MB) }
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

function Get-ServerState {
  # What is running, asked of the server rather than of a file we wrote: a
  # PID file says what was started, /health says what is answering.
  $state = [ordered]@{ running = $false; loading = $false; model = $null; api = "$($endpoint.LocalRoot)/v1"; chat = $endpoint.LocalRoot }
  if ($endpoint.LanRoots.Count) {
    $state.lanApi = "$($endpoint.LanRoots[0])/v1"
    $state.lanChat = $endpoint.LanRoots[0]
    if ($endpoint.MdnsRoot) { $state.mdnsChat = $endpoint.MdnsRoot }
  }
  try {
    $health = Invoke-RestMethod -Uri "$($endpoint.LocalRoot)/health" -TimeoutSec 2
    if ($health.status -eq 'ok') { $state.running = $true }
    elseif ($health.status -eq 'loading model') { $state.loading = $true }
  } catch {
    # Nothing answering is a normal state here, not an error to report.
  }
  if ($state.running) {
    try {
      $props = Invoke-RestMethod -Uri "$($endpoint.LocalRoot)/props" -TimeoutSec 2
      $state.model = $props.model_alias
      if (-not $state.model -and $props.default_generation_settings) { $state.model = $props.default_generation_settings.model }
    } catch {}
  }
  if (Test-Path -LiteralPath $statePath) {
    try { $state.launched = (Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json) } catch {}
  }
  return $state
}

function Start-Detached {
  # Same trick llmfit.ps1 uses to leave a server behind: handing the
  # redirection to sh gives the child its file descriptors directly, so the log
  # does not stop the moment this process goes away. On Windows there is a
  # console to own the process instead.
  param([string[]]$Arguments, [string]$LogPath)
  $powerShellHost = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
  if ($onWindows) {
    Start-Process -FilePath $powerShellHost -ArgumentList (@('-NoProfile','-ExecutionPolicy','Bypass','-File') + $Arguments) `
      -WorkingDirectory $root -WindowStyle Minimized | Out-Null
    return
  }
  $quoted = @($powerShellHost, '-NoProfile', '-File') + $Arguments | ForEach-Object { "'" + ($_ -replace "'", "'\''") + "'" }
  $command = 'nohup ' + ($quoted -join ' ') + ' > ' + "'$LogPath'" + ' 2>&1 < /dev/null &'
  & '/bin/sh' '-c' $command
}

# --------------------------------------------------------------- API shapes

function Get-StatePayload {
  $models = @()
  foreach ($key in $modelKeys) {
    $model = $catalog[$key]
    $weightsPath = Join-Path $modelsDirectory $model.modelFile
    $mmprojPath = if ($model.mmprojFile) { Join-Path $modelsDirectory $model.mmprojFile } else { $null }
    $specType = Get-PlatformSetting -Block $model.speculative -Platform $platform -Name 'specType'
    if (-not $specType -and $model.mtp) { $specType = 'draft-mtp' }
    $models += [ordered]@{
      key = $key; name = $model.name; alias = $model.alias
      note = $model.note
      hasVision = [bool]$model.mmprojFile
      weightsMiB = if (Test-Path -LiteralPath $weightsPath) { Get-FileMiB $weightsPath }
                   elseif ($model.modelBytes) { [double]$model.modelBytes / 1MB } else { 0 }
      visionMiB = if ($mmprojPath -and (Test-Path -LiteralPath $mmprojPath)) { Get-FileMiB $mmprojPath }
                  elseif ($model.mmprojBytes) { [double]$model.mmprojBytes / 1MB } else { 0 }
      downloaded = (Test-Path -LiteralPath $weightsPath)
      visionDownloaded = if ($mmprojPath) { Test-Path -LiteralPath $mmprojPath } else { $false }
      specType = $specType
      summary = $model.geometry.summary
      cacheDefault = (Get-CacheType -Model $model -ServerConfig $serverConfig -Platform $platform).Type
      maxContext = $model.geometry.maxContext
    }
  }
  return [ordered]@{
    platform = $platform
    architecture = $architecture
    backends = @($backendKeys | ForEach-Object {
      $b = Get-BudgetForBackend -Key $_
      [ordered]@{
        key = $b.Key; name = $b.Name; installed = $b.Installed; devices = $b.Devices
        budgetMiB = $b.BudgetMiB; heldBackMiB = $b.HeldBackMiB; systemRamMiB = $b.SystemRamMiB
        speculative = $b.Speculative
      }
    })
    models = $models
    cacheTypes = @($serverConfig.cacheTypeOptions | ForEach-Object {
      [ordered]@{ type = $_; bytes = $serverConfig.cacheTypeBytes[$_] }
    })
    contextOptions = @($serverConfig.contextOptions)
    server = Get-ServerState
    panel = @{ roots = $panelRoots }
  }
}

function Get-FitPayload {
  param($Request)
  $model = $catalog[[string]$Request.modelKey]
  if (-not $model) { throw "Unknown model key: $($Request.modelKey)" }
  $backendKey = [string]$Request.backendKey
  $backend = $backends[$backendKey]
  if (-not $backend) { throw "Unknown backend: $backendKey" }
  $useVision = [bool]$Request.vision
  $cacheType = [string]$Request.cacheType
  if (-not $cacheType) { $cacheType = (Get-CacheType -Model $model -ServerConfig $serverConfig -Platform $platform).Type }
  $cacheBytes = [double]$serverConfig.cacheTypeBytes[$cacheType]

  $budget = Get-BudgetForBackend -Key $backendKey
  # Sizes come off disk when the file is here and out of the catalog's declared
  # figures when it is not, so the table means the same thing before and after
  # a download rather than reading as "0 MiB, fits comfortably".
  $weightsMiB = Get-FileMiB (Join-Path $modelsDirectory $model.modelFile)
  if (-not $weightsMiB -and $model.modelBytes) { $weightsMiB = [double]$model.modelBytes / 1MB }
  $visionMiB = 0
  if ($useVision -and $model.mmprojFile) {
    $visionMiB = Get-FileMiB (Join-Path $modelsDirectory $model.mmprojFile)
    if (-not $visionMiB -and $model.mmprojBytes) { $visionMiB = [double]$model.mmprojBytes / 1MB }
  }
  $overhead = Get-ModelOverhead -Model $model -ServerConfig $serverConfig -Platform $platform -OnWindows $onWindows -UseVision $useVision
  $rows = Get-FitTable -Model $model -ServerConfig $serverConfig -BudgetMiB $budget.BudgetMiB `
    -WeightsMiB $weightsMiB -VisionMiB $visionMiB -CacheBytes $cacheBytes -OverheadMiB $overhead.MiB

  $specRows = @{}
  foreach ($row in $rows) {
    $plan = Get-SpecPlan -Model $model -Backend $backend -BackendKey $backendKey -Platform $platform `
      -BudgetMiB $budget.BudgetMiB -TotalMiB $row.TotalMiB -ContextSize $row.Context
    $specRows["$($row.Context)"] = [ordered]@{
      use = $plan.Use; type = $plan.Type; costMiB = $plan.CostMiB; reason = $plan.Reason; note = $plan.Note
    }
  }
  return [ordered]@{
    budgetMiB = $budget.BudgetMiB; heldBackMiB = $budget.HeldBackMiB
    deviceName = if ($budget.Devices.Count) { $budget.Devices[0].name } else { 'system RAM' }
    weightsMiB = $weightsMiB; visionMiB = $visionMiB
    overheadMiB = $overhead.MiB; overheadCalibrated = $overhead.Calibrated; overheadMissing = $overhead.Missing
    cacheType = $cacheType; cacheBytes = $cacheBytes
    downloaded = (Test-Path -LiteralPath (Join-Path $modelsDirectory $model.modelFile))
    rows = @($rows | ForEach-Object {
      [ordered]@{ context = $_.Context; kvMiB = $_.KvMiB; totalMiB = $_.TotalMiB; fits = $_.Fits; tight = $_.Tight }
    })
    spec = $specRows
  }
}

function Start-Run {
  param($Request)
  $modelKey = [string]$Request.modelKey
  $backendKey = [string]$Request.backendKey
  $model = $catalog[$modelKey]
  if (-not $model) { throw "Unknown model key: $modelKey" }
  $useVision = [bool]$Request.vision
  $useSpec = [bool]$Request.spec
  $context = [int]$Request.context
  $cacheType = [string]$Request.cacheType

  Remove-Item -LiteralPath $progressPath -Force -ErrorAction SilentlyContinue
  $launched = [ordered]@{
    modelKey = $modelKey; alias = $model.alias; backendKey = $backendKey; vision = $useVision
    spec = $useSpec; context = $context; cacheType = $cacheType; startedAt = (Get-Date).ToString('o')
  }
  [System.IO.File]::WriteAllText($statePath, ($launched | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))

  $arguments = @((Join-Path $root 'fetch.ps1'), '-ModelKey', $modelKey, '-Backend', $backendKey, '-ProgressPath', $progressPath)
  if ($useVision) { $arguments += '-Vision' }
  if ($useSpec) { $arguments += '-Spec' }
  Start-Detached -Arguments $arguments -LogPath (Join-Path $root 'llmfit-fetch.log')
  return @{ started = $true }
}

function Get-ProgressPayload {
  if (-not (Test-Path -LiteralPath $progressPath)) { return @{ state = 'idle' } }
  try {
    $progress = Get-Content -Raw -LiteralPath $progressPath | ConvertFrom-Json
  } catch { return @{ state = 'starting' } }
  # Percentages are computed here, from the file on disk against the size the
  # server reported, because that is the only number that is true while a
  # transfer is in flight.
  $artifacts = @()
  foreach ($item in @($progress.artifacts)) {
    $have = if (Test-Path -LiteralPath $item.path) { (Get-Item -LiteralPath $item.path).Length } else { 0 }
    $artifacts += [ordered]@{
      label = $item.label; done = $item.done; expected = $item.expected; have = $have
      percent = if ($item.done) { 100 } elseif ($item.expected -gt 0) { [math]::Round(100 * $have / $item.expected, 1) } else { $null }
    }
  }
  return [ordered]@{ state = $progress.state; message = $progress.message; artifacts = $artifacts }
}

function Start-Server {
  $launched = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
  $serveArguments = @(
    (Join-Path $root 'serve.ps1'),
    '-ModelKey', $launched.modelKey, '-Backend', $launched.backendKey,
    '-Context', "$($launched.context)", '-CacheType', $launched.cacheType
  )
  if ($launched.vision) { $serveArguments += '-Vision' }
  if ($launched.spec) { $serveArguments += '-Spec' }
  Stop-Server | Out-Null
  Start-Detached -Arguments $serveArguments -LogPath (Join-Path $root 'llama-server.log')
  return @{ started = $true }
}

function Stop-Server {
  $stopped = 0
  Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and $_.Path.StartsWith($toolsDirectory, [System.StringComparison]::OrdinalIgnoreCase) } |
    ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue; $stopped++ }
  if ($stopped) { Start-Sleep -Milliseconds 500 }
  return @{ stopped = $stopped }
}

# ---------------------------------------------------------------- the server

$listener = New-Object System.Net.HttpListener
# '+' binds every interface. The panel follows server.json's host: if the API
# is open to the network, so is the thing that starts it, which is the only
# arrangement that makes sense on a machine you drive from the sofa.
$prefix = if ($endpoint.IsWildcard) { "http://+:$uiPort/" } else { "http://$($serverConfig.host):$uiPort/" }
try {
  $listener.Prefixes.Add($prefix)
  $listener.Start()
} catch {
  # '+' needs a URL reservation on Windows and gets one on Linux for free.
  # Falling back to the loopback is better than refusing to start at all.
  $listener = New-Object System.Net.HttpListener
  $prefix = "http://127.0.0.1:$uiPort/"
  $listener.Prefixes.Add($prefix)
  $listener.Start()
}

Write-Host ''
Write-Host '  LLMFIT PANEL' -ForegroundColor Cyan
Write-Host "  $('=' * 46)" -ForegroundColor Cyan
foreach ($rootUrl in $panelRoots) { Write-Host "  $rootUrl" }
if ($endpoint.MdnsRoot) { Write-Host "  http://$(([uri]$endpoint.MdnsRoot).Host):$uiPort" }
Write-Host ''
Write-Host '  Ctrl+C stops the panel. It does not stop a model that is already loaded.' -ForegroundColor DarkGray
Write-Host ''

$contentTypes = @{ '.html' = 'text/html; charset=utf-8'; '.css' = 'text/css; charset=utf-8'; '.js' = 'text/javascript; charset=utf-8'; '.svg' = 'image/svg+xml' }

function Send-Response {
  param($Context, [int]$Status, [string]$Body, [string]$ContentType = 'application/json')
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
  $Context.Response.StatusCode = $Status
  $Context.Response.ContentType = $ContentType
  $Context.Response.ContentLength64 = $bytes.Length
  # The panel is also opened from a phone; nothing here is cached so a reload
  # after a config edit shows the edit.
  $Context.Response.Headers.Add('Cache-Control', 'no-store')
  $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
  $Context.Response.OutputStream.Close()
}

while ($listener.IsListening) {
  $context = $null
  try { $context = $listener.GetContext() } catch { break }
  try {
    $path = $context.Request.Url.AbsolutePath
    $method = $context.Request.HttpMethod
    $body = $null
    if ($method -eq 'POST' -and $context.Request.HasEntityBody) {
      $reader = New-Object System.IO.StreamReader($context.Request.InputStream, $context.Request.ContentEncoding)
      $raw = $reader.ReadToEnd(); $reader.Close()
      if ($raw) { $body = $raw | ConvertFrom-Json }
    }

    switch -Regex ("$method $path") {
      '^GET /$' {
        $file = Join-Path $uiDirectory 'index.html'
        Send-Response -Context $context -Status 200 -Body (Get-Content -Raw -LiteralPath $file) -ContentType $contentTypes['.html']
      }
      '^GET /(app\.css|app\.js)$' {
        $name = Split-Path -Leaf $path
        $file = Join-Path $uiDirectory $name
        $extension = [System.IO.Path]::GetExtension($name)
        Send-Response -Context $context -Status 200 -Body (Get-Content -Raw -LiteralPath $file) -ContentType $contentTypes[$extension]
      }
      '^GET /api/state$' { Send-Response -Context $context -Status 200 -Body ((Get-StatePayload) | ConvertTo-Json -Depth 8) }
      '^GET /api/status$' { Send-Response -Context $context -Status 200 -Body ((Get-ServerState) | ConvertTo-Json -Depth 6) }
      '^GET /api/progress$' { Send-Response -Context $context -Status 200 -Body ((Get-ProgressPayload) | ConvertTo-Json -Depth 6) }
      '^POST /api/fit$' { Send-Response -Context $context -Status 200 -Body ((Get-FitPayload -Request $body) | ConvertTo-Json -Depth 8) }
      '^POST /api/prepare$' { Send-Response -Context $context -Status 200 -Body ((Start-Run -Request $body) | ConvertTo-Json) }
      '^POST /api/serve$' { Send-Response -Context $context -Status 200 -Body ((Start-Server) | ConvertTo-Json) }
      '^POST /api/stop$' { Send-Response -Context $context -Status 200 -Body ((Stop-Server) | ConvertTo-Json) }
      default { Send-Response -Context $context -Status 404 -Body '{"error":"no such route"}' }
    }
  } catch {
    # One bad request must not take the panel down with it: the machine it runs
    # on is often not the machine anyone is sitting at.
    try { Send-Response -Context $context -Status 500 -Body (@{ error = "$($_.Exception.Message)" } | ConvertTo-Json) } catch {}
  }
}
