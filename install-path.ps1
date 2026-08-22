$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$required = @(
  (Join-Path $root 'bin'),
  (Join-Path $root 'tools\node'),
  (Join-Path $root 'tools\pi\node_modules\.bin')
)
$current = [Environment]::GetEnvironmentVariable('Path', 'User')
$entries = @($current -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
foreach ($entry in $required) {
  if ($entries -notcontains $entry) { $entries += $entry }
}
[Environment]::SetEnvironmentVariable('Path', ($entries -join ';'), 'User')
foreach ($entry in $required) { Write-Host "PATH: $entry" -ForegroundColor DarkGray }
Write-Host ''
Write-Host 'Installed for the current user.' -ForegroundColor Green
Write-Host 'Open a new terminal and run: llmfit' -ForegroundColor Cyan
Write-Host 'You can also use START.cmd without touching PATH.'
