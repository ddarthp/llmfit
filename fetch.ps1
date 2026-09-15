param(
  [Parameter(Mandatory = $true)][string]$ModelKey,
  [switch]$Vision,
  [switch]$Spec,
  [string]$Backend,
  # Where to write progress as it goes. The web panel polls this file rather
  # than parsing curl's progress bar out of a pipe: the bar is drawn with
  # carriage returns for a terminal, and a second consumer of it would be
  # reverse-engineering someone else's output format.
  [string]$ProgressPath
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$modelsDirectory = Join-Path $root 'models'
$toolsDirectory = Join-Path $root 'tools'
$downloadsDirectory = Join-Path $root 'downloads'

$onWindows = if ($null -ne $IsWindows) { [bool]$IsWindows } else { $true }
$serverExe = if ($onWindows) { 'llama-server.exe' } else { 'llama-server' }
$curlCommand = if ($onWindows) { 'curl.exe' } else { 'curl' }

. (Join-Path $root (Join-Path 'lib' 'config.ps1'))
. (Join-Path $root (Join-Path 'lib' 'artifacts.ps1'))

# Progress is a single JSON file rewritten at each step, not a log to be
# tailed: a poller that misses a write still sees the current state on its
# next request, which a stream of events does not give you for free.
$script:steps = @()
function Write-Progress-File {
  param([string]$State, [string]$Message)
  if (-not $ProgressPath) { return }
  $payload = [ordered]@{
    state = $State
    message = $Message
    updated = (Get-Date).ToString('o')
    artifacts = $script:steps
  }
  $json = $payload | ConvertTo-Json -Depth 5
  # Written whole and moved into place, so a poll never reads half a file.
  $temporary = "$ProgressPath.tmp"
  [System.IO.File]::WriteAllText($temporary, $json, (New-Object System.Text.UTF8Encoding($false)))
  Move-Item -LiteralPath $temporary -Destination $ProgressPath -Force
}

function Get-RemoteBytes {
  # The size the panel divides by to draw a bar. Hugging Face answers it in
  # x-linked-size because the file itself is behind a redirect to a CDN; a
  # plain content-length on the first response is the size of the redirect.
  param([string]$Url)
  try {
    $headers = & $curlCommand -sIL --max-time 20 $Url 2>$null
    $linked = @($headers | Select-String -Pattern '^x-linked-size:\s*(\d+)' -AllMatches)
    if ($linked.Count) { return [long]$linked[-1].Matches[0].Groups[1].Value }
    $length = @($headers | Select-String -Pattern '^content-length:\s*(\d+)' -AllMatches)
    if ($length.Count) { return [long]$length[-1].Matches[0].Groups[1].Value }
  } catch {}
  return 0
}

function Add-Artifact {
  param([string]$Label, [string]$Path, [string]$Url, [string]$Sha256)
  $needed = -not (Test-Path -LiteralPath $Path)
  $script:steps += [ordered]@{
    label = $Label; path = $Path; expected = 0; needed = $needed; done = (-not $needed)
  }
  return $script:steps.Count - 1
}

$catalog = Read-JsonConfig -Name 'models.json' -Root $root
$backends = Read-JsonConfig -Name 'backends.json' -Root $root
$model = $catalog[$ModelKey]
if (-not $model) { throw "Unknown model key: $ModelKey" }

# Everything this configuration needs on disk, listed before anything is
# fetched, so the panel can show the whole bill up front rather than one
# surprise at a time.
$wanted = @()
$wanted += @{ Label = $model.modelFile; Path = (Join-Path $modelsDirectory $model.modelFile); Url = $model.modelUrl; Sha256 = $model.modelSha256; Bytes = $model.modelBytes }
if ($Vision) {
  $wanted += @{ Label = $model.mmprojFile; Path = (Join-Path $modelsDirectory $model.mmprojFile); Url = $model.mmprojUrl; Sha256 = $model.mmprojSha256; Bytes = $model.mmprojBytes }
}
if ($Spec -and $model.mtp -and $model.mtp.mode -eq 'draft-model') {
  $wanted += @{ Label = $model.mtp.file; Path = (Join-Path $modelsDirectory $model.mtp.file); Url = $model.mtp.url; Sha256 = $model.mtp.sha256; Bytes = $model.mtp.bytes }
}

foreach ($item in $wanted) { [void](Add-Artifact -Label $item.Label -Path $item.Path -Url $item.Url -Sha256 $item.Sha256) }
Write-Progress-File -State 'starting' -Message 'Checking what is already here'

for ($i = 0; $i -lt $wanted.Count; $i++) {
  $item = $wanted[$i]
  if ($script:steps[$i].done) { continue }
  # The catalog carries the size; the HEAD is only for an entry that does not.
  $script:steps[$i].expected = if ($item.Bytes) { [long]$item.Bytes } else { Get-RemoteBytes -Url $item.Url }
  Write-Progress-File -State 'downloading' -Message "Downloading $($item.Label)"
  Ensure-Artifact -Path $item.Path -Url $item.Url -Sha256 $item.Sha256 -CurlCommand $curlCommand
  $script:steps[$i].done = $true
  Write-Progress-File -State 'downloading' -Message "Verified $($item.Label)"
}

if ($Backend) {
  $selected = $backends[$Backend]
  if (-not $selected) { throw "Unknown backend: $Backend" }
  if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $toolsDirectory $selected.folder) $serverExe))) {
    Write-Progress-File -State 'downloading' -Message "Preparing backend $($selected.name)"
    Ensure-Backend -Backend $selected -ToolsDirectory $toolsDirectory `
      -DownloadsDirectory $downloadsDirectory -ServerExe $serverExe -CurlCommand $curlCommand
  }
}

Write-Progress-File -State 'ready' -Message 'Everything verified and in place'
Write-Host 'READY'
