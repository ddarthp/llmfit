# Which address to hand out, and to whom. Dot-sourced by llmfit.ps1 and
# serve.ps1 because both have to answer that question and answering it
# differently in two places is how a summary starts describing a server that
# is not the one running.
#
# The distinction this file exists for: the address llama-server BINDS to and
# the address something CONNECTS to are not the same string. config/server.json
# sets the bind address, and the useful value there is 0.0.0.0 - every
# interface, which is what makes the server reachable from another machine.
# But 0.0.0.0 is not an address you can connect to. On Linux and macOS it
# happens to work by falling through to the loopback; on Windows it fails
# outright. So the launcher binds with what the config says, talks to the
# loopback itself, and gives other machines a real address off this file.

function Test-WildcardBind {
  # The three spellings of "every interface" that llama.cpp accepts.
  param([string]$BindHost)
  return ($BindHost -eq '0.0.0.0' -or $BindHost -eq '::' -or $BindHost -eq '*')
}

function Get-PrimaryLanAddress {
  # The address another machine on the LAN would actually reach this one at,
  # asked of the routing table rather than guessed from a list of interfaces.
  # A UDP socket that is "connected" sends no packets: the call only makes the
  # OS choose a route, and the socket's local endpoint is then the address that
  # route leaves from. 192.0.2.1 is TEST-NET-1, reserved for documentation and
  # routed nowhere, so nothing is contacted even if the link is up.
  #
  # Without this, a machine with Docker, a VPN and a wifi card offers three
  # equally plausible addresses and the launcher has no way to say which one to
  # paste. This is how it knows.
  $socket = $null
  try {
    $socket = New-Object System.Net.Sockets.Socket(
      [System.Net.Sockets.AddressFamily]::InterNetwork,
      [System.Net.Sockets.SocketType]::Dgram,
      [System.Net.Sockets.ProtocolType]::Udp)
    $socket.Connect('192.0.2.1', 9)
    $address = $socket.LocalEndPoint.Address.ToString()
    if ($address -eq '0.0.0.0' -or $address -like '127.*') { return $null }
    return $address
  } catch {
    # No default route: a machine with no network, or one where every route is
    # down. Nothing to advertise, and that is an answer rather than an error.
    return $null
  } finally {
    if ($socket) { $socket.Dispose() }
  }
}

function Get-LanAddresses {
  # Every IPv4 address a wildcard bind is actually listening on, primary first.
  # Loopback is excluded because it is the one address that is NOT the LAN, and
  # so is 169.254/16: that range means DHCP never answered, and nothing on the
  # network can reach it.
  $primary = Get-PrimaryLanAddress
  $found = @()
  try {
    foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
      if ($nic.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) { continue }
      if ($nic.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Loopback) { continue }
      $properties = $null
      # A NIC can disappear between being listed and being asked about itself.
      try { $properties = $nic.GetIPProperties() } catch { continue }
      foreach ($unicast in $properties.UnicastAddresses) {
        if ($unicast.Address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { continue }
        $address = $unicast.Address.ToString()
        if ($address -like '127.*' -or $address -like '169.254.*') { continue }
        $found += [pscustomobject]@{
          Address = $address
          Interface = $nic.Name
          IsPrimary = ($address -eq $primary)
        }
      }
    }
  } catch {}
  # PowerShell unrolls a one-element array on return and a scalar has no
  # .Count, which is the same trap Get-BackendDevices documents in llmfit.ps1.
  return @(@($found | Where-Object { $_.IsPrimary }) + @($found | Where-Object { -not $_.IsPrimary }))
}

function Get-MdnsName {
  # <hostname>.local, but only where something on this machine answers for it.
  # macOS always does. On Linux that is Avahi, which most desktop distributions
  # run and most server images do not. Windows ships no mDNS responder, so the
  # name is not offered there rather than offered and wrong.
  param([bool]$OnWindows, [bool]$OnMacOS, [bool]$OnLinux)
  if ($OnWindows) { return $null }
  # Matched with -like rather than -Name: avahi rewrites its own argv, so the
  # process name PowerShell reports is the whole 'avahi-daemon: running
  # [host.local]' string and an exact-name lookup finds nothing.
  if ($OnLinux) {
    $responder = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like 'avahi-daemon*' })
    if (-not $responder.Count) { return $null }
  }
  try {
    $name = [System.Net.Dns]::GetHostName()
    if ([string]::IsNullOrWhiteSpace($name)) { return $null }
    # A machine already called something.local should not become something.local.local.
    if ($name -like '*.local') { return $name }
    return "$name.local"
  } catch { return $null }
}

function Get-ServerEndpoint {
  # One object with every address question already answered, so callers only
  # decide how to print it.
  param($ServerConfig, [bool]$OnWindows, [bool]$OnMacOS, [bool]$OnLinux)
  $bindHost = "$($ServerConfig.host)"
  $port = $ServerConfig.port
  $wildcard = Test-WildcardBind -BindHost $bindHost
  $localHost = if ($wildcard) { '127.0.0.1' } else { $bindHost }
  $lan = if ($wildcard) { @(Get-LanAddresses) } else { @() }
  $mdns = if ($wildcard) { Get-MdnsName -OnWindows $OnWindows -OnMacOS $OnMacOS -OnLinux $OnLinux } else { $null }
  return [pscustomobject]@{
    BindHost = $bindHost
    Port = $port
    IsWildcard = $wildcard
    LocalRoot = "http://${localHost}:$port"
    LanAddresses = $lan
    LanRoots = @($lan | ForEach-Object { "http://$($_.Address):$port" })
    MdnsRoot = if ($mdns) { "http://${mdns}:$port" } else { $null }
  }
}
