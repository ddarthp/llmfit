# Reading config/ the same way everywhere. The launcher, the downloader and the
# web panel all need the catalog as HASHTABLES rather than as the objects
# ConvertFrom-Json returns, because lib/fit.ps1 asks blocks whether they
# .Contains() a platform name - a method a PSCustomObject does not have. One
# front end reading the catalog differently from another is how two of them end
# up disagreeing about what a model declares.

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

function Read-JsonConfig {
  param([string]$Name, [string]$Root)
  $path = Join-Path (Join-Path $Root 'config') $Name
  if (-not (Test-Path -LiteralPath $path)) { throw "Missing configuration file: $path" }
  return ConvertTo-Hashtable (Get-Content -Raw -LiteralPath $path | ConvertFrom-Json)
}
