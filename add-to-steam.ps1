param(
  # The name the library shows. One per name: running this twice replaces the
  # entry rather than adding a second one.
  [string]$Name = 'llmfit',
  # Which launcher the shortcut runs. The panel is the point of this - a
  # terminal wizard is not something you drive from a Steam library - but
  # START.sh works too if you want the wizard in a console window.
  [string]$Target = 'PANEL.sh',
  # shortcuts.vdf belongs to the Steam client while it is running: it holds its
  # own copy in memory and writes it back on exit, so an edit made underneath a
  # live Steam is thrown away without a word. This refuses instead.
  [switch]$Force,
  [switch]$Remove
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

$onLinux = if ($null -ne $IsLinux) { [bool]$IsLinux } else { $false }
if (-not $onLinux) {
  throw 'Non-Steam shortcuts are only wired up for Linux here, where Gaming Mode is the reason to want one.'
}

# ------------------------------------------------------------- binary VDF
#
# shortcuts.vdf is Valve's binary key-value format: 0x00 opens a nested map
# under a NUL-terminated key, 0x01 is a NUL-terminated string, 0x02 is a
# little-endian int32, and 0x08 closes the current map. The file is one map
# called "shortcuts" whose keys are "0", "1", "2" and so on.
#
# It is parsed and re-emitted whole rather than patched in place, and the
# round trip was checked against a real 47-entry library before this script
# was allowed to write anything: parse then emit reproduced the file byte for
# byte. That is the only reason writing to it is defensible at all.

function Read-VdfMap {
  param([byte[]]$Data, [ref]$Offset)
  $items = @()
  while ($true) {
    $tag = $Data[$Offset.Value]; $Offset.Value++
    if ($tag -eq 0x08) { return ,$items }
    $start = $Offset.Value
    while ($Data[$Offset.Value] -ne 0) { $Offset.Value++ }
    $key = [System.Text.Encoding]::UTF8.GetString($Data, $start, $Offset.Value - $start)
    $Offset.Value++
    switch ($tag) {
      0x00 {
        $inner = Read-VdfMap -Data $Data -Offset $Offset
        $items += [pscustomobject]@{ Kind = 'map'; Key = $key; Value = $inner }
      }
      0x01 {
        $start = $Offset.Value
        while ($Data[$Offset.Value] -ne 0) { $Offset.Value++ }
        $value = [System.Text.Encoding]::UTF8.GetString($Data, $start, $Offset.Value - $start)
        $Offset.Value++
        $items += [pscustomobject]@{ Kind = 'str'; Key = $key; Value = $value }
      }
      0x02 {
        $value = [System.BitConverter]::ToInt32($Data, $Offset.Value)
        $Offset.Value += 4
        $items += [pscustomobject]@{ Kind = 'int'; Key = $key; Value = $value }
      }
      default { throw "Unknown VDF tag 0x{0:x2} at offset {1}" -f $tag, ($Offset.Value - 1) }
    }
  }
}

function Write-VdfMap {
  param($Items)
  $stream = New-Object System.IO.MemoryStream
  foreach ($item in $Items) {
    switch ($item.Kind) {
      'map' {
        $stream.WriteByte(0x00)
        $key = [System.Text.Encoding]::UTF8.GetBytes($item.Key); $stream.Write($key, 0, $key.Length); $stream.WriteByte(0)
        $inner = Write-VdfMap -Items $item.Value; $stream.Write($inner, 0, $inner.Length)
      }
      'str' {
        $stream.WriteByte(0x01)
        $key = [System.Text.Encoding]::UTF8.GetBytes($item.Key); $stream.Write($key, 0, $key.Length); $stream.WriteByte(0)
        $value = [System.Text.Encoding]::UTF8.GetBytes([string]$item.Value); $stream.Write($value, 0, $value.Length); $stream.WriteByte(0)
      }
      'int' {
        $stream.WriteByte(0x02)
        $key = [System.Text.Encoding]::UTF8.GetBytes($item.Key); $stream.Write($key, 0, $key.Length); $stream.WriteByte(0)
        $value = [System.BitConverter]::GetBytes([int]$item.Value); $stream.Write($value, 0, 4)
      }
    }
  }
  $stream.WriteByte(0x08)
  return $stream.ToArray()
}

function Get-Crc32 {
  # Steam derives a non-Steam app's id from crc32(exe + appname), which is also
  # what names its artwork files. Written out because .NET has no CRC-32 and
  # pulling one in would break the rule this project keeps everywhere else.
  param([string]$Text)
  $table = New-Object 'uint32[]' 256
  for ($i = 0; $i -lt 256; $i++) {
    $value = [uint32]$i
    for ($bit = 0; $bit -lt 8; $bit++) {
      # Written as decimals: PowerShell reads a hex literal wider than int32 as a
      # negative number, and [uint32] then refuses it.
      if ($value -band 1) { $value = [uint32](3988292384 -bxor ($value -shr 1)) }
      else { $value = [uint32]($value -shr 1) }
    }
    $table[$i] = $value
  }
  $crc = [uint32]4294967295
  foreach ($byte in [System.Text.Encoding]::UTF8.GetBytes($Text)) {
    $crc = [uint32]($table[($crc -bxor $byte) -band 0xFF] -bxor ($crc -shr 8))
  }
  return [uint32]($crc -bxor 4294967295)
}

# ------------------------------------------------------------------ where

# Wrapped in @() around the WHOLE pipeline, not just the list: with one Steam
# installation Where-Object returns a bare string, and $steamRoots[0] on a
# string is its first character. Same trap Get-BackendDevices documents.
$steamRoots = @(@(
  (Join-Path $HOME '.steam/steam/userdata'),
  (Join-Path $HOME '.local/share/Steam/userdata'),
  (Join-Path $HOME '.var/app/com.valvesoftware.Steam/.local/share/Steam/userdata')
) | Where-Object { Test-Path -LiteralPath $_ })
if (-not $steamRoots.Count) { throw 'No Steam userdata directory found. Is Steam installed for this user?' }

# One account is the normal case; more than one means the shortcut has to go
# somewhere specific rather than into whichever was listed first.
$accounts = @(Get-ChildItem -LiteralPath $steamRoots[0] -Directory | Where-Object { $_.Name -match '^\d+$' -and $_.Name -ne '0' })
if (-not $accounts.Count) { throw "No Steam account folders under $($steamRoots[0])" }
if ($accounts.Count -gt 1) {
  Write-Host "  More than one Steam account here; using the one signed in most recently." -ForegroundColor DarkGray
  $accounts = @($accounts | Sort-Object LastWriteTime -Descending)
}
$configDirectory = Join-Path $accounts[0].FullName 'config'
$shortcutsPath = Join-Path $configDirectory 'shortcuts.vdf'
$gridDirectory = Join-Path $configDirectory 'grid'

$steamRunning = [bool](Get-Process -Name 'steam' -ErrorAction SilentlyContinue)
if ($steamRunning -and -not $Force) {
  Write-Host ''
  Write-Host '  Steam is running.' -ForegroundColor Yellow
  Write-Host '  It keeps its own copy of shortcuts.vdf and writes it back when it exits, so' -ForegroundColor Yellow
  Write-Host '  anything written now is discarded without an error. Close Steam and run this' -ForegroundColor Yellow
  Write-Host '  again, or pass -Force if you know it is about to be restarted anyway.' -ForegroundColor Yellow
  Write-Host ''
  exit 1
}

# ------------------------------------------------------------------ write

$exe = '"' + (Join-Path $root $Target) + '"'
$startDirectory = '"' + $root + [System.IO.Path]::DirectorySeparatorChar + '"'
$appIdUnsigned = [uint32]((Get-Crc32 -Text ($exe + $Name)) -bor 2147483648)
$appId = [int][long]($appIdUnsigned - 4294967296)

$bytes = [System.IO.File]::ReadAllBytes($shortcutsPath)
$offset = 1
while ($bytes[$offset] -ne 0) { $offset++ }
$rootKey = [System.Text.Encoding]::UTF8.GetString($bytes, 1, $offset - 1)
$offset++
# No @() here: Read-VdfMap already returns the array wrapped with the comma
# operator, so wrapping it again yields an array holding one array.
$entries = Read-VdfMap -Data $bytes -Offset ([ref]$offset)

# Same rule the harness configuration follows: back the file up once, before
# the first write, and leave every other entry exactly as it was.
$backup = "$shortcutsPath.llmfit-backup"
if (-not (Test-Path -LiteralPath $backup)) {
  Copy-Item -LiteralPath $shortcutsPath -Destination $backup -Force
  Write-Host "  backup saved: $backup" -ForegroundColor DarkGray
}

function Get-Field { param($Fields, [string]$Name)
  $match = @($Fields | Where-Object { $_.Key.ToLowerInvariant() -eq $Name })
  if ($match.Count) { return $match[0].Value }
  return $null
}

$kept = @($entries | Where-Object { (Get-Field -Fields $_.Value -Name 'appname') -ne $Name })
$removed = $entries.Count - $kept.Count

if (-not $Remove) {
  $fields = @(
    [pscustomobject]@{ Kind = 'int'; Key = 'appid'; Value = $appId }
    [pscustomobject]@{ Kind = 'str'; Key = 'AppName'; Value = $Name }
    [pscustomobject]@{ Kind = 'str'; Key = 'Exe'; Value = $exe }
    [pscustomobject]@{ Kind = 'str'; Key = 'StartDir'; Value = $startDirectory }
    [pscustomobject]@{ Kind = 'str'; Key = 'icon'; Value = (Join-Path $root 'ui/steam/icon.png') }
    [pscustomobject]@{ Kind = 'str'; Key = 'ShortcutPath'; Value = '' }
    [pscustomobject]@{ Kind = 'str'; Key = 'LaunchOptions'; Value = '' }
    [pscustomobject]@{ Kind = 'int'; Key = 'IsHidden'; Value = 0 }
    [pscustomobject]@{ Kind = 'int'; Key = 'AllowDesktopConfig'; Value = 1 }
    [pscustomobject]@{ Kind = 'int'; Key = 'AllowOverlay'; Value = 1 }
    [pscustomobject]@{ Kind = 'int'; Key = 'OpenVR'; Value = 0 }
    [pscustomobject]@{ Kind = 'int'; Key = 'Devkit'; Value = 0 }
    [pscustomobject]@{ Kind = 'str'; Key = 'DevkitGameID'; Value = '' }
    [pscustomobject]@{ Kind = 'int'; Key = 'DevkitOverrideAppID'; Value = 0 }
    [pscustomobject]@{ Kind = 'int'; Key = 'LastPlayTime'; Value = 0 }
    [pscustomobject]@{ Kind = 'str'; Key = 'FlatpakAppID'; Value = '' }
    [pscustomobject]@{ Kind = 'map'; Key = 'tags'; Value = @() }
  )
  $kept += [pscustomobject]@{ Kind = 'map'; Key = "$($kept.Count)"; Value = $fields }
}

# Steam keys entries by position, so they are renumbered after a removal.
for ($i = 0; $i -lt $kept.Count; $i++) { $kept[$i].Key = "$i" }

$output = New-Object System.IO.MemoryStream
$output.WriteByte(0x00)
$keyBytes = [System.Text.Encoding]::UTF8.GetBytes($rootKey)
$output.Write($keyBytes, 0, $keyBytes.Length); $output.WriteByte(0)
$body = Write-VdfMap -Items $kept
$output.Write($body, 0, $body.Length)
$output.WriteByte(0x08)
[System.IO.File]::WriteAllBytes($shortcutsPath, $output.ToArray())

# Artwork, named the way Steam looks for it: <appid> for the wide grid, with
# p, _hero and _logo for the rest. Missing files are not an error; the entry
# just shows Steam's placeholder.
if (-not $Remove) {
  New-Item -ItemType Directory -Force -Path $gridDirectory | Out-Null
  $artwork = @{
    "$appIdUnsigned.png" = 'grid-wide.png'
    "${appIdUnsigned}p.png" = 'grid-portrait.png'
    "${appIdUnsigned}_hero.png" = 'hero.png'
    "${appIdUnsigned}_logo.png" = 'logo.png'
  }
  foreach ($pair in $artwork.GetEnumerator()) {
    $source = Join-Path $root (Join-Path 'ui/steam' $pair.Value)
    if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination (Join-Path $gridDirectory $pair.Key) -Force }
  }
}

Write-Host ''
if ($Remove) {
  Write-Host "  Removed $removed entry named '$Name' from the Steam library." -ForegroundColor Green
} else {
  Write-Host "  '$Name' is in your Steam library." -ForegroundColor Green
  Write-Host "    runs      : $exe" -ForegroundColor DarkGray
  Write-Host "    app id    : $appIdUnsigned" -ForegroundColor DarkGray
  Write-Host "    artwork   : $gridDirectory" -ForegroundColor DarkGray
  if ($removed) { Write-Host "    replaced  : $removed earlier entry with the same name" -ForegroundColor DarkGray }
}
Write-Host '  Start Steam to see it. In Gaming Mode it is under Library > Non-Steam.' -ForegroundColor DarkGray
Write-Host ''
