<#
.SYNOPSIS
  Apply a network scenario from profiles/<device>.json to this Windows machine.

.EXAMPLE
  .\Apply-Profile.ps1 -Device kevin-laptop -Scenario ssh-link
  .\Apply-Profile.ps1 -Device kevin-laptop -Scenario home
  .\Apply-Profile.ps1 -Device kevin-laptop -Scenario ssh-link -DryRun
  .\Apply-Profile.ps1 -Help
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [string]$Device,

  [Parameter(Position = 1)]
  [string]$Scenario,

  [string]$ProfilesDir = (Join-Path $PSScriptRoot "..\profiles"),

  [switch]$DryRun,

  [switch]$Help
)

$ErrorActionPreference = "Stop"

function Show-Usage {
  @"
Usage: Apply-Profile.ps1 -Device <device> -Scenario <scenario-name> [options]

Required:
  -Device <device>    Which profiles\<device>.json file to use -- a label
                       you choose, not required to match this machine's
                       actual hostname. Devices that want identical settings
                       (e.g. every Windows laptop) can share one file; pass
                       its name explicitly instead of relying on hostname
                       lookup.
  -Scenario <name>    Which top-level key in that JSON file to apply
                       (e.g. "home", "ssh-link").

Options:
  -ProfilesDir PATH   Directory containing profile JSON files
                       (default: ..\profiles relative to this script)
  -DryRun             Show current state and planned changes, apply nothing
  -Help               Show this help

Example:
  .\Apply-Profile.ps1 -Device kevin-laptop -Scenario ssh-link
  .\Apply-Profile.ps1 -Device kevin-laptop -Scenario home -DryRun
"@ | Write-Host
}

if ($Help) {
  Show-Usage
  exit 0
}

if (-not $Device -or -not $Scenario) {
  Write-Error "Both -Device and -Scenario are required." -ErrorAction Continue
  Show-Usage
  exit 1
}

function Test-IsAdministrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = [Security.Principal.WindowsPrincipal]::new($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not $DryRun -and -not (Test-IsAdministrator)) {
  Write-Error "This script changes network configuration and must be run from an elevated (Administrator) PowerShell." -ErrorAction Continue
  exit 1
}

$deviceLower = $Device.ToLowerInvariant()
$profilePath = Join-Path $ProfilesDir "$deviceLower.json"

if (-not (Test-Path $profilePath)) {
  Write-Error "Profile file not found: $profilePath" -ErrorAction Continue
  $pattern = Join-Path $ProfilesDir "*.json"
  $matches = Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue
  if ($matches) {
    Write-Host "Available device profiles:"
    $matches | ForEach-Object { Write-Host "  $($_.Name)" }
  } else {
    Write-Host "No device profiles found in $ProfilesDir"
  }
  exit 1
}

$hostProfile = Get-Content -Raw -Path $profilePath | ConvertFrom-Json

if (-not ($hostProfile.PSObject.Properties.Name -contains $Scenario)) {
  Write-Error "Scenario '$Scenario' not found in $profilePath" -ErrorAction Continue
  Write-Host "Available scenarios for ${Device}:"
  $hostProfile.PSObject.Properties.Name | ForEach-Object { Write-Host "  $_" }
  exit 1
}

Write-Host "Using profile: $profilePath (scenario: $Scenario)"
$profileData = $hostProfile.$Scenario

# --- Small validation helpers -----------------------------------------------

function ConvertTo-UInt32FromIPv4 {
  param([string]$IPAddress)
  $bytes = [System.Net.IPAddress]::Parse($IPAddress).GetAddressBytes()
  if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($bytes) }
  return [BitConverter]::ToUInt32($bytes, 0)
}

function Test-SameSubnet {
  param([string]$AddressA, [string]$AddressB, [int]$Prefix)
  try {
    $aNum = ConvertTo-UInt32FromIPv4 $AddressA
    $bNum = ConvertTo-UInt32FromIPv4 $AddressB
  } catch {
    return $null
  }
  $mask = if ($Prefix -eq 0) { [uint32]0 } else { [uint32]([UInt32]::MaxValue -shl (32 - $Prefix)) }
  return (($aNum -band $mask) -eq ($bNum -band $mask))
}

function Test-ValidIPv4 {
  param([string]$IPAddress)
  $parsed = $null
  if (-not [System.Net.IPAddress]::TryParse($IPAddress, [ref]$parsed)) { return $false }
  return $parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
}

# --- Interface discovery -----------------------------------------------------

function Get-RoleAdapters {
  param([string]$Role)
  $physical = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)
  if ($Role -eq "wifi") {
    return @($physical | Where-Object { $_.PhysicalMediaType -like "*802.11*" })
  } else {
    return @($physical | Where-Object { $_.PhysicalMediaType -eq "802.3" })
  }
}

# --- Snapshot / suspicious checks --------------------------------------------

function Show-AdapterState {
  param([string]$Label, [string]$Role, $Adapter)

  Write-Host "--- $Label : $Role ($($Adapter.Name)) ---"
  $idx = $Adapter.ifIndex
  $ipIface = Get-NetIPInterface -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue
  $addrs = @(Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue)
  $route = Get-NetRoute -InterfaceIndex $idx -DestinationPrefix "0.0.0.0/0" -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
  $dns = Get-DnsClientServerAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue

  Write-Host "    link status: $($Adapter.Status)"
  Write-Host "    dhcp: $($ipIface.Dhcp)"
  if ($addrs.Count -gt 0) {
    foreach ($a in $addrs) { Write-Host "    address: $($a.IPAddress)/$($a.PrefixLength)" }
  } else {
    Write-Host "    address: <none>"
  }
  Write-Host "    gateway: $(if ($route) { $route.NextHop } else { '<none>' })"
  Write-Host "    dns: $(if ($dns -and $dns.ServerAddresses.Count -gt 0) { $dns.ServerAddresses -join ', ' } else { '<none>' })"

  if ($addrs | Where-Object { $_.IPAddress -like "169.254.*" }) {
    Write-Warning "$Role ($($Adapter.Name)) has an APIPA (169.254.x.x) address - DHCP may not be handing out a lease."
  }
  if ($Adapter.Status -ne "Up") {
    Write-Host "    note: link is not Up ($($Adapter.Status)) - config can still be applied but won't be active until connected."
  }
}

function Set-RoleNetwork {
  param(
    [string]$Role,
    $Adapter,
    [PSCustomObject]$Config
  )

  $mode = $Config.mode
  $address = $Config.address
  $prefix = $Config.prefix
  $gateway = $Config.gateway
  $dns = $Config.dns

  $idx = $Adapter.ifIndex
  Write-Host "Configuring $Role ($($Adapter.Name)): mode=$mode"

  if ($DryRun) {
    Write-Host "  [dry-run] would set mode=$mode address=$address/$prefix gateway=$gateway dns=$($dns -join ',')"
    return
  }

  if ($mode -eq "dhcp") {
    Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue |
      Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    Get-NetRoute -InterfaceIndex $idx -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
      Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
    Set-NetIPInterface -InterfaceIndex $idx -Dhcp Enabled
    Set-DnsClientServerAddress -InterfaceIndex $idx -ResetServerAddresses
  } elseif ($mode -eq "static") {
    if (-not $address -or -not $prefix) {
      Write-Error "  $Role.mode is 'static' but address/prefix missing in profile." -ErrorAction Continue
      exit 1
    }
    Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue |
      Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    Set-NetIPInterface -InterfaceIndex $idx -Dhcp Disabled

    $ipParams = @{
      InterfaceIndex = $idx
      IPAddress      = $address
      PrefixLength   = $prefix
      AddressFamily  = "IPv4"
    }
    if ($gateway) { $ipParams["DefaultGateway"] = $gateway }
    New-NetIPAddress @ipParams | Out-Null

    if ($dns -and $dns.Count -gt 0) {
      Set-DnsClientServerAddress -InterfaceIndex $idx -ServerAddresses $dns
    } else {
      Set-DnsClientServerAddress -InterfaceIndex $idx -ResetServerAddresses
    }
  } else {
    Write-Error "  Unknown mode '$mode' for $Role." -ErrorAction Continue
    exit 1
  }
}

function Confirm-RoleApplied {
  param([string]$Role, $Adapter, [PSCustomObject]$Config)

  $idx = $Adapter.ifIndex
  $addrs = @(Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue)
  $route = Get-NetRoute -InterfaceIndex $idx -DestinationPrefix "0.0.0.0/0" -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1

  if ($Config.mode -eq "static") {
    if ($addrs | Where-Object { $_.IPAddress -eq $Config.address -and [int]$_.PrefixLength -eq [int]$Config.prefix }) {
      Write-Host "    OK: $Role has expected address $($Config.address)/$($Config.prefix)"
    } else {
      Write-Warning "    expected address $($Config.address)/$($Config.prefix) not found on $($Adapter.Name)."
    }
    if ($Config.gateway) {
      if ($route -and $route.NextHop -eq $Config.gateway) {
        Write-Host "    OK: default gateway is $($Config.gateway)"
      } else {
        Write-Warning "    expected gateway $($Config.gateway), got '$(if ($route) { $route.NextHop } else { '<none>' })'"
      }
    }
  } else {
    if ($addrs | Where-Object { $_.IPAddress -like "169.254.*" }) {
      Write-Warning "    still showing an APIPA address after switching to dhcp - may not have a lease yet."
    } else {
      Write-Host "    OK: dhcp mode set."
    }
  }
}

# --- Main --------------------------------------------------------------------

foreach ($role in @("ethernet", "wifi")) {
  $config = $profileData.$role
  if (-not $config) {
    Write-Host ""
    Write-Host "Leaving $role alone (not in profile)."
    continue
  }

  $candidates = Get-RoleAdapters -Role $role
  if ($candidates.Count -eq 0) {
    Write-Host ""
    Write-Warning "No $role adapter found on this machine, skipping."
    continue
  }
  if ($candidates.Count -gt 1) {
    Write-Warning "Multiple candidate $role adapters found ($(($candidates | ForEach-Object { $_.Name }) -join ', ')); using '$($candidates[0].Name)'."
  }
  $adapter = $candidates[0]

  if ($config.mode -eq "static") {
    if ($config.gateway) {
      $same = Test-SameSubnet -AddressA $config.address -AddressB $config.gateway -Prefix $config.prefix
      if ($same -eq $false) {
        Write-Warning "$role gateway $($config.gateway) does not appear to be in the same subnet as $($config.address)/$($config.prefix)."
      }
    }
    foreach ($d in ($config.dns | Where-Object { $_ })) {
      if (-not (Test-ValidIPv4 $d)) {
        Write-Warning "$role dns entry '$d' doesn't look like a valid IPv4 address."
      }
    }
  }

  Write-Host ""
  Show-AdapterState -Label "BEFORE" -Role $role -Adapter $adapter
  Set-RoleNetwork -Role $role -Adapter $adapter -Config $config

  if (-not $DryRun) {
    Start-Sleep -Seconds 1
    Show-AdapterState -Label "AFTER" -Role $role -Adapter $adapter
    Confirm-RoleApplied -Role $role -Adapter $adapter -Config $config
  }
}

Write-Host ""
Write-Host "Done."
