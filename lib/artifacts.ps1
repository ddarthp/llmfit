# Downloading, verifying and unpacking everything this project does not ship:
# model weights, vision encoders, draft models and llama.cpp itself. Moved out
# of llmfit.ps1 when the web panel needed the same code - a second
# implementation of "is this file complete" is how a project starts trusting a
# half-downloaded 16 GB GGUF.
#
# The rule every function here enforces: the SHA-256 is the contract. Not
# whether the file exists, not whether curl exited cleanly, not how many bytes
# arrived. Nothing is extracted or loaded before the hash matches.

function Get-Sha256 {
  param([string]$Path)
  return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Ensure-Artifact {
  # CurlCommand is passed rather than read from a script variable because this
  # file has two callers now. On Windows the bundled binary is curl.exe and
  # calling it unqualified finds the PowerShell alias for Invoke-WebRequest
  # instead, which takes none of these flags.
  param([string]$Path, [string]$Url, [string]$Sha256, [string]$CurlCommand = 'curl')
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
  param(
    $Backend, [string]$ToolsDirectory, [string]$DownloadsDirectory,
    [string]$ServerExe, [string]$CurlCommand = 'curl'
  )
  $destination = Join-Path $ToolsDirectory $Backend.folder
  if (Test-Path -LiteralPath (Join-Path $destination $ServerExe)) { return }
  Write-Host "  Preparing backend: $($Backend.name)" -ForegroundColor Cyan
  New-Item -ItemType Directory -Force -Path $destination | Out-Null
  foreach ($archive in $Backend.archives) {
    $archivePath = Join-Path $DownloadsDirectory $archive.file
    Ensure-Artifact -Path $archivePath -Url $archive.url -Sha256 $archive.sha256 -CurlCommand $CurlCommand
    $strip = if ($archive.stripComponents) { [int]$archive.stripComponents } else { 0 }
    Expand-Package -ArchivePath $archivePath -Destination $destination -StripComponents $strip
  }
  if (-not (Test-Path -LiteralPath (Join-Path $destination $ServerExe))) {
    throw "Backend package does not contain ${ServerExe}: $destination"
  }
}
