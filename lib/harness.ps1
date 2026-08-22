# Definition of the supported harnesses and how to register the local provider
# in each one. Dot-sourced from llmfit.ps1.
#
# Principle: registering the provider is ADDITIVE. The user's default model is
# never touched, because that would leave all their other projects pointing at
# a local server that is usually switched off. The model is chosen per
# invocation, with a flag.

# Only the model that is actually loaded gets registered, with the context the
# server was actually started with. Advertising the whole catalog would be a
# lie twice over: the server holds one model at a time, and declaring a model's
# maximum context when 64K was loaded makes the harness plan for a window that
# does not exist.

function Configure-Pi {
  param($Model, [int]$Context, [string]$ApiBase, $ServerConfig)
  $providerKey = $ServerConfig.harness.piProvider
  $directory = Join-Path $env:USERPROFILE '.pi\agent'
  New-Item -ItemType Directory -Force -Path $directory | Out-Null

  $path = Join-Path $directory 'models.json'
  if (Test-Path -LiteralPath $path) {
    Backup-Once -Path $path
    $config = ConvertTo-Hashtable (Get-Content -Raw -LiteralPath $path | ConvertFrom-Json)
  } else { $config = [ordered]@{} }
  if (-not $config.Contains('providers')) { $config.providers = [ordered]@{} }
  $config.providers[$providerKey] = [ordered]@{
    baseUrl = $ApiBase
    api = 'openai-completions'
    apiKey = 'none'
    compat = [ordered]@{ supportsDeveloperRole = $false; supportsReasoningEffort = $false }
    models = @([ordered]@{
      id = $Model.alias
      name = $Model.name
      reasoning = $true
      input = @('text', 'image')
      contextWindow = $Context
      maxTokens = $Model.maxTokens
      cost = [ordered]@{ input = 0; output = 0; cacheRead = 0; cacheWrite = 0 }
    })
  }
  Write-Utf8NoBom -Path $path -Content ($config | ConvertTo-Json -Depth 12)

  $settingsPath = Join-Path $directory 'settings.json'
  if (Test-Path -LiteralPath $settingsPath) {
    Backup-Once -Path $settingsPath
    $settings = ConvertTo-Hashtable (Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json)
  } else { $settings = [ordered]@{} }

  # Pi INSTALLS every registered package at startup. If one fails to build, Pi
  # will not open. That is why the list comes from config and is empty by
  # default.
  $wanted = @($ServerConfig.harness.piPackages)
  $retired = @($ServerConfig.harness.piPackagesRetired)
  $packages = @()
  if ($settings.Contains('packages')) { $packages += @($settings.packages) }
  $packages += $wanted
  $packages = @($packages | Where-Object { $_ } | Select-Object -Unique | Where-Object { $retired -notcontains $_ })
  if ($packages.Count) {
    $settings.packages = $packages
  } elseif ($settings.Contains('packages')) {
    $settings.Remove('packages')
    Write-Host '  restored: removed Pi packages that were never requested' -ForegroundColor DarkGray
  }

  # Undo the global override that earlier versions used to apply.
  if ($settings.Contains('defaultProvider') -and $settings.defaultProvider -eq $providerKey) { $settings.Remove('defaultProvider') }
  if ($settings.Contains('defaultModel') -and $settings.defaultModel -eq $Model.alias) { $settings.Remove('defaultModel') }
  Write-Utf8NoBom -Path $settingsPath -Content ($settings | ConvertTo-Json -Depth 12)
}

function Configure-OpenCode {
  param($Model, [int]$Context, [string]$ApiBase, $ServerConfig)
  $providerKey = $ServerConfig.harness.openCodeProvider
  $directory = Join-Path $env:USERPROFILE '.config\opencode'
  $path = Join-Path $directory 'opencode.json'
  New-Item -ItemType Directory -Force -Path $directory | Out-Null
  if (Test-Path -LiteralPath $path) {
    Backup-Once -Path $path
    $config = ConvertTo-Hashtable (Get-Content -Raw -LiteralPath $path | ConvertFrom-Json)
  } else { $config = [ordered]@{ '$schema' = 'https://opencode.ai/config.json' } }
  if (-not $config.Contains('provider')) { $config.provider = [ordered]@{} }

  # tool_call and attachment are mandatory: without them OpenCode does not hand
  # tools to the model and does not allow image attachments, leaving it as a
  # plain chat.
  $models = [ordered]@{}
  $models[$Model.alias] = [ordered]@{
    name = $Model.name
    reasoning = $true
    tool_call = $true
    attachment = $true
    modalities = [ordered]@{ input = @('text', 'image'); output = @('text') }
    limit = [ordered]@{ context = $Context; output = $Model.maxTokens }
    options = [ordered]@{ temperature = 0.6; topP = 0.95 }
  }
  $config.provider[$providerKey] = [ordered]@{
    npm = '@ai-sdk/openai-compatible'
    name = 'llama.cpp local'
    options = [ordered]@{ baseURL = $ApiBase; apiKey = 'local' }
    models = $models
  }
  if ($config.Contains('model') -and "$($config.model)" -match '^llama-?cpp/') { $config.Remove('model') }
  if ($providerKey -ne 'llama-cpp' -and $config.provider.Contains('llama-cpp')) { $config.provider.Remove('llama-cpp') }
  Write-Utf8NoBom -Path $path -Content ($config | ConvertTo-Json -Depth 12)
}

function Set-ManagedBlock {
  param([string]$Path, [string]$Content)
  $begin = '# >>> llmfit BEGIN (generated by llmfit.ps1; do not edit by hand)'
  $end = '# <<< llmfit END'
  $body = ''
  if (Test-Path -LiteralPath $Path) {
    Backup-Once -Path $Path
    $pattern = [regex]::Escape($begin) + '.*?' + [regex]::Escape($end)
    $body = ([regex]::Replace((Get-Content -Raw -LiteralPath $Path), $pattern, '', [System.Text.RegularExpressions.RegexOptions]::Singleline)).TrimEnd()
  }
  $block = "$begin`n$Content`n$end`n"
  if ([string]::IsNullOrWhiteSpace($body)) { Write-Utf8NoBom -Path $Path -Content $block }
  else { Write-Utf8NoBom -Path $Path -Content "$body`n`n$block" }
}

function Configure-Codex {
  param($Model, [int]$Context, [string]$ApiBase, $ServerConfig)
  $profileName = $ServerConfig.harness.codexProfile
  $directory = Join-Path $env:USERPROFILE '.codex'
  New-Item -ItemType Directory -Force -Path $directory | Out-Null

  # Earlier versions wrote llama-local.config.toml, a standalone file Codex
  # never reads: profiles are resolved from config.toml.
  $orphan = Join-Path $directory 'llama-local.config.toml'
  if (Test-Path -LiteralPath $orphan) { Remove-Item -LiteralPath $orphan -Force }

  $content = @"
[model_providers.llama-cpp]
name = "llama.cpp local"
base_url = "$ApiBase"
wire_api = "responses"
requires_openai_auth = false
stream_idle_timeout_ms = 600000

[profiles.$profileName]
model = "$($Model.alias)"
model_provider = "llama-cpp"
model_context_window = $Context
model_supports_reasoning_summaries = false
model_reasoning_summary = "none"
"@
  Set-ManagedBlock -Path (Join-Path $directory 'config.toml') -Content $content
}

function Get-Harnesses {
  param(
    [string]$Alias, [string]$ApiRoot, [string]$ApiBase,
    [string]$PiProvider, [string]$OpenCodeProvider, [string]$CodexProfile
  )


  return @(
    [pscustomobject]@{
      Name = 'Pi'; Api = 'OpenAI chat'; Supported = $true; SupportNote = ''
      Installed = [bool](Get-Command pi -ErrorAction SilentlyContinue)
      Line = "pi --provider $PiProvider --model $Alias"
      Note = "To switch to your cloud provider without leaving the session: pi --models `"<provider>/*,$PiProvider/*`"  (Ctrl+P cycles)"
      Configure = ${function:Configure-Pi}
      IsConfigured = {
        param($ServerConfig)
        $path = Join-Path $env:USERPROFILE '.pi\agent\models.json'
        if (-not (Test-Path -LiteralPath $path)) { return $false }
        try { return $null -ne ((Get-Content -Raw -LiteralPath $path | ConvertFrom-Json).providers.($ServerConfig.harness.piProvider)) } catch { return $false }
      }
    },
    [pscustomobject]@{
      Name = 'OpenCode'; Api = 'OpenAI chat'; Supported = $true; SupportNote = ''
      Installed = [bool](Get-Command opencode -ErrorAction SilentlyContinue)
      Line = "opencode -m $OpenCodeProvider/$Alias"
      Note = 'Inside the TUI you can switch models live with the model picker.'
      Configure = ${function:Configure-OpenCode}
      IsConfigured = {
        param($ServerConfig)
        $path = Join-Path $env:USERPROFILE '.config\opencode\opencode.json'
        if (-not (Test-Path -LiteralPath $path)) { return $false }
        try { return $null -ne ((Get-Content -Raw -LiteralPath $path | ConvertFrom-Json).provider.($ServerConfig.harness.openCodeProvider)) } catch { return $false }
      }
    },
    [pscustomobject]@{
      # llama-server serves its own chat UI at the root URL, compiled into the
      # binary. Nothing to install, and it is already running: the only thing
      # missing was telling anyone it exists.
      Name = 'Browser'; Api = 'built-in chat UI'; Supported = $true; SupportNote = ''
      Installed = $true
      Line = $ApiRoot
      OpenUrl = $ApiRoot
      Note = 'Opens in your default browser. Supports images when the model has vision.'
      Configure = $null
      IsConfigured = { param($ServerConfig) return $true }
    },
    [pscustomobject]@{
      Name = 'Codex'; Api = 'OpenAI responses'; Supported = $true; SupportNote = ''
      Installed = [bool](Get-Command codex -ErrorAction SilentlyContinue)
      Line = "codex --profile $CodexProfile"
      Note = 'Without the flag, Codex keeps using your normal configuration.'
      Configure = ${function:Configure-Codex}
      IsConfigured = {
        param($ServerConfig)
        $path = Join-Path $env:USERPROFILE '.codex\config.toml'
        if (-not (Test-Path -LiteralPath $path)) { return $false }
        return (Get-Content -Raw -LiteralPath $path) -match ("(?m)^\[profiles\." + [regex]::Escape($ServerConfig.harness.codexProfile) + "\]")
      }
    }
  )
}
