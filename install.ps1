#Requires -Version 5.1
<#
.SYNOPSIS
  opencode-hop installer for Windows.

.DESCRIPTION
  Downloads the asset for this machine, verifies it, installs it to
  %USERPROFILE%\bin\opencode-hop.exe, updates the user PATH, and prepares the
  9router marker when no stock opencode is visible.

  Run install.cmd for the user-facing entry point. This file is also attached
  to each release.
#>
[CmdletBinding()]
param(
  [string]$Tag = '',
  [switch]$Check,
  [switch]$DryRun,
  [switch]$Help
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$Repo = 'TkgJamuKeliling/opencode-hop'
$Prog = 'opencode-hop'
$BinDir = Join-Path $env:USERPROFILE 'bin'
$Target = Join-Path $BinDir "$Prog.exe"
$State = Join-Path $env:USERPROFILE '.local\state\opencode\service-hop.json'
$Marker = Join-Path $env:USERPROFILE '.config\opencode\opencode.json'

$Temp = $null
$Asset = ''
$Release = ''
$Base = ''
$Arch = ''
$Machine = ''
$Format = ''
$Checksum = ''
$VersionLine = ''
$StockFound = $false
$StockStatus = ''
$MarkerStatus = ''
$PathStatus = ''
$ServiceStatus = 'not running'
$ServiceWasRunning = $false
$DownloadStatus = ''
$DownloadOk = $false
$ReadOnly = $false

function Write-Row {
  param([string]$Label, [string]$Value)
  Write-Host ('{0,-9} {1}' -f $Label, $Value)
}

function Show-Usage {
  @"
opencode-hop installer

Usage:
  install.cmd [--tag <tag>] [--check] [--dry-run] [--help]
  powershell -File install.ps1 [-Tag <tag>] [-Check] [-DryRun] [-Help]

Options:
  --tag, -Tag <tag>   Install a specific release (for example v2.3.4)
  --check, -Check     Report what would happen; no changes, no download
  --dry-run, -DryRun  Print the install plan; no changes, no download
  --help, -Help       Show this help

Downloads from:
  https://github.com/$Repo/releases
"@ | Write-Host
}

function Invoke-Download {
  param([string]$Url, [string]$OutFile, [int]$Retries = 3)
  for ($i = 1; $i -le $Retries; $i++) {
    try {
      Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $OutFile -ErrorAction Stop
      return
    } catch {
      if ($i -eq $Retries) { throw }
      Start-Sleep -Seconds (2 * $i)
    }
  }
}

function Get-Sha256 {
  param([string]$Path)
  (Get-FileHash -Algorithm SHA256 -Path $Path).Hash.ToLowerInvariant()
}

function Get-PeMachine {
  param([string]$Path)
  $stream = [IO.File]::OpenRead($Path)
  $reader = New-Object -TypeName IO.BinaryReader -ArgumentList $stream
  try {
    if ($stream.Length -lt 64) { return 'too-small' }
    $stream.Position = 0
    if ($reader.ReadUInt16() -ne 0x5A4D) { return 'not-pe' }
    $stream.Position = 0x3C
    $peOffset = $reader.ReadInt32()
    if ($peOffset -lt 0 -or $peOffset -gt ($stream.Length - 24)) { return 'truncated' }
    $stream.Position = $peOffset
    if ($reader.ReadUInt32() -ne 0x00004550) { return 'not-pe' }
    $machine = $reader.ReadUInt16()
    switch ($machine) {
      0x8664 { return 'x64' }
      0xAA64 { return 'arm64' }
      0x014C { return 'x86' }
      default { return ('other-0x{0:X4}' -f $machine) }
    }
  } finally {
    $reader.Dispose()
  }
}

function Get-MachineArch {
  $osArch = ''
  try {
    $osArch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
  } catch {}
  switch ($osArch) {
    'X64' { return 'x64' }
    'Arm64' { return 'arm64' }
    'X86' { throw '32-bit Windows is not supported; use 64-bit Windows.' }
    'Arm' { throw '32-bit ARM Windows is not supported.' }
  }

  $arch = $env:PROCESSOR_ARCHITEW6432
  if (-not $arch) { $arch = $env:PROCESSOR_ARCHITECTURE }
  if (-not $arch) { throw 'could not determine the CPU architecture' }
  switch ($arch.ToUpperInvariant()) {
    'AMD64' { return 'x64' }
    'ARM64' { return 'arm64' }
    default { throw "unsupported CPU: $arch" }
  }
}

function Get-StockOpencode {
  $oldPath = $env:Path
  try {
    if ($env:APPDATA) {
      $env:Path = (Join-Path $env:APPDATA 'npm') + ';' + $env:Path
    }
    return Get-Command opencode -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  } finally {
    $env:Path = $oldPath
  }
}

function Get-UserPathValue {
  $key = $null
  try {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $false)
    if (-not $key) { return $null }
    $raw = $key.GetValue('Path', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    if ($null -eq $raw) { return $null }
    $kind = $key.GetValueKind('Path')
    return [pscustomobject]@{ Value = [string]$raw; Kind = $kind }
  } catch {
    return $null
  } finally {
    if ($key) { $key.Dispose() }
  }
}

function Test-UserPathContainsBin {
  $current = Get-UserPathValue
  if (-not $current -or -not $current.Value) { return $false }
  $expanded = [Environment]::ExpandEnvironmentVariables($current.Value)
  foreach ($part in $expanded.Split(';')) {
    if ($part -and ($part.TrimEnd('\') -ieq $BinDir.TrimEnd('\'))) { return $true }
  }
  return $false
}

function Add-UserPath {
  try {
    if (Test-UserPathContainsBin) {
      $script:PathStatus = 'already on user PATH'
    } else {
      $current = Get-UserPathValue
      $userPath = ''
      if ($current) { $userPath = $current.Value.TrimEnd(';') }
      if ($userPath) { $newPath = "$BinDir;$userPath" } else { $newPath = $BinDir }
      $kind = [Microsoft.Win32.RegistryValueKind]::String
      if ($current -and $current.Kind -eq [Microsoft.Win32.RegistryValueKind]::ExpandString) {
        $kind = [Microsoft.Win32.RegistryValueKind]::ExpandString
      }
      $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
      if (-not $key) { $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment') }
      try {
        $key.SetValue('Path', $newPath, $kind)
      } finally {
        $key.Dispose()
      }
      $script:PathStatus = 'added to user PATH'
      try {
        Add-Type -Namespace Win32 -Name NativeMethods -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
        $result = [UIntPtr]::Zero
        [Win32.NativeMethods]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result) | Out-Null
      } catch {}
    }
  } catch {
    $script:PathStatus = "could not update user PATH: $($_.Exception.Message)"
    Write-Warning "could not update the user PATH. Add $BinDir manually."
  }

  $has = $false
  foreach ($part in $env:Path.Split(';')) {
    if ($part -and ($part.TrimEnd('\') -ieq $BinDir.TrimEnd('\'))) { $has = $true; break }
  }
  if (-not $has) { $env:Path = "$BinDir;$env:Path" }
}

function Get-ServiceState {
  $script:ServiceWasRunning = $false
  $script:ServiceStatus = 'not running'
  if (Test-Path $Target) {
    try {
      $out = & $Target service status 2>$null
      if ($LASTEXITCODE -eq 0) {
        $text = (($out | Out-String).Trim())
        if ($text -and $text -ne 'stopped') {
          $script:ServiceWasRunning = $true
          $script:ServiceStatus = "running at $text"
        }
        return
      }
    } catch {}
    $script:ServiceStatus = 'unknown (installed binary did not run)'
  }
  if (Test-Path $State) {
    try {
      $json = Get-Content -Path $State -Raw | ConvertFrom-Json
      $servicePid = [int]$json.pid
      if ($servicePid -gt 0 -and (Get-Process -Id $servicePid -ErrorAction SilentlyContinue)) {
        if ($script:ReadOnly) {
          $script:ServiceStatus = "running (pid $servicePid; binary did not run)"
          return
        }
        throw "a service is still running (pid $servicePid), but the installed binary cannot be queried. Stop it first, then run this installer again."
      }
    } catch {
      if ($_.Exception.Message -like 'a service is still running*') { throw }
    }
    $script:ServiceStatus = 'stale service state'
  }
}

function Stop-ServiceIfRunning {
  if (-not $ServiceWasRunning) { return }
  & $Target service stop 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "could not stop the running service. Run '$Target service stop' and try again."
  }
  for ($i = 0; $i -lt 20; $i++) {
    $out = & $Target service status 2>$null
    $text = (($out | Out-String).Trim())
    if (-not $text -or $text -eq 'stopped') {
      $script:ServiceStatus = 'stopped for upgrade'
      return
    }
    Start-Sleep -Milliseconds 100
  }
  throw "the service is still running at $text; stop it manually and try again."
}

function Start-ServiceIfWasRunning {
  if (-not $ServiceWasRunning) { return }
  for ($i = 0; $i -lt 10; $i++) {
    try {
      $out = & $Target service start 2>$null
      if ($LASTEXITCODE -eq 0) {
        $text = (($out | Out-String).Trim())
        $script:ServiceStatus = "restarted at $text"
        return
      }
    } catch {}
    Start-Sleep -Milliseconds 300
  }
  $script:ServiceStatus = 'stopped (start failed)'
  Write-Warning "could not restart the service; run: $Target service start"
}

function Install-Binary {
  param([string]$File)
  if (-not (Test-Path $BinDir)) {
    New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
  }
  $backup = Join-Path $BinDir ".$Prog.previous.exe"
  $hadOld = $false
  if (Test-Path $Target) {
    if (Test-Path $backup) { Remove-Item $backup -Force -ErrorAction SilentlyContinue }
    for ($i = 0; $i -lt 10; $i++) {
      try {
        Move-Item -Force -Path $Target -Destination $backup -ErrorAction Stop
        break
      } catch {
        if ($i -eq 9) { throw "could not move the old binary out of the way: $Target" }
        Start-Sleep -Milliseconds 300
      }
    }
    $hadOld = $true
  } elseif (Test-Path $backup) {
    $hadOld = $true
  }

  try {
    Copy-Item -Force -Path $File -Destination $Target -ErrorAction Stop
    Unblock-File -Path $Target -ErrorAction SilentlyContinue
    $version = & $Target --version 2>&1
    $code = $LASTEXITCODE
    if ($code -ne 0) {
      $text = (($version | Out-String).Trim())
      if (-not $text) { $text = '(no output)' }
      throw "the new binary did not run (exit $code):`n$text"
    }
    $text = (($version | Out-String).Trim())
    if (-not $text) { throw 'the new binary ran but printed no version.' }
    $script:VersionLine = ($text -split '\r?\n')[0]
  } catch {
    if (Test-Path $Target) { Remove-Item $Target -Force -ErrorAction SilentlyContinue }
    if ($hadOld -and (Test-Path $backup)) {
      Move-Item -Force -Path $backup -Destination $Target -ErrorAction SilentlyContinue
      if ($ServiceWasRunning) { try { & $Target service start 2>$null | Out-Null } catch {} }
    }
    throw "install failed: $($_.Exception.Message)`nRolled back to the previous binary."
  }
  if (Test-Path $backup) { Remove-Item $backup -Force -ErrorAction SilentlyContinue }
}

function Set-Marker {
  if ($StockFound) {
    $script:MarkerStatus = 'stock opencode found; not needed'
    return
  }
  if (Test-Path $Marker) {
    $script:MarkerStatus = 'already exists'
    return
  }
  try {
    $dir = Split-Path -Parent $Marker
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    [IO.File]::WriteAllText($Marker, '{}')
    $script:MarkerStatus = "created $Marker"
  } catch {
    $script:MarkerStatus = "could not create $Marker"
    Write-Warning "could not create $Marker`: $($_.Exception.Message)"
  }
}

function Get-MarkerPlan {
  if ($StockFound) {
    $script:MarkerStatus = 'stock opencode found; not needed'
  } elseif (Test-Path $Marker) {
    $script:MarkerStatus = 'already exists'
  } else {
    $script:MarkerStatus = "would create $Marker"
  }
}

function Test-Download {
  $script:DownloadOk = $false
  try {
    $response = Invoke-WebRequest -UseBasicParsing -Method Head -Uri "$Base/$Asset" -ErrorAction Stop
    if ($response.StatusCode -eq 200) {
      $script:DownloadOk = $true
      $script:DownloadStatus = 'available (200)'
    } else {
      $script:DownloadStatus = "not available (HTTP $($response.StatusCode))"
    }
  } catch {
    $status = $null
    if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
    if ($status) { $script:DownloadStatus = "not available (HTTP $status)" }
    else { $script:DownloadStatus = 'unreachable' }
  }
}

function Show-Summary {
  Write-Host ''
  Write-Host 'opencode-hop installer'
  Write-Host ''
  Write-Row 'Machine' $Machine
  Write-Row 'Asset' $Asset
  Write-Row 'Release' $Release
  if ($Checksum) { Write-Row 'Checksum' $Checksum }
  if ($Format) { Write-Row 'Format' $Format }
  if ($DownloadStatus) { Write-Row 'Download' $DownloadStatus }
  Write-Row 'Stock' $StockStatus
  Write-Row '9router' $MarkerStatus
  Write-Row 'Install' $Target
  Write-Row 'PATH' $PathStatus
  Write-Row 'Service' $ServiceStatus
  if ($VersionLine) { Write-Row 'Version' $VersionLine }
  Write-Host ''
}

function Show-Done {
  if ($PathStatus -like 'added*') {
    Write-Host 'Done. Open a new terminal.'
  } else {
    Write-Host 'Done.'
  }
  if (-not $StockFound -and (Test-Path $Marker)) {
    Write-Host 'For 9router: refresh the dashboard, then CLI Tools -> OpenCode.'
  }
}

try {
  if ($Help) {
    Show-Usage
    exit 0
  }

  if (-not $env:OS -or $env:OS -ne 'Windows_NT') {
    throw 'this installer is for Windows. On macOS or Linux, run install.sh.'
  }

  if ($Tag) {
    if ($Tag -notmatch '^[A-Za-z0-9._-]+$' -or $Tag -match '^-') { throw "invalid tag: $Tag" }
    if ($Tag -match '^[0-9]') { $Tag = "v$Tag" }
  }

  if ($Tag) {
    $Base = "https://github.com/$Repo/releases/download/$Tag"
    $Release = $Tag
  } else {
    $Base = "https://github.com/$Repo/releases/latest/download"
    $Release = 'latest'
  }

  $Arch = Get-MachineArch
  $Machine = "Windows $Arch"
  $Asset = "$Prog-windows-$Arch.exe"

  $stock = Get-StockOpencode
  if ($stock) {
    $StockFound = $true
    $StockStatus = "found ($($stock.Source))"
  } else {
    $StockFound = $false
    $StockStatus = 'not found'
  }

  if ($Check -or $DryRun) {
    $script:ReadOnly = $true
    Get-ServiceState
    Get-MarkerPlan
    if (Test-UserPathContainsBin) {
      $PathStatus = 'already on user PATH'
    } else {
      $PathStatus = 'would add to user PATH'
    }
    if ($Check) {
      Test-Download
    } else {
      $DownloadStatus = "would download $Base/$Asset"
    }
    Show-Summary
    Write-Host 'No changes made.'
    if ($Check -and -not $DownloadOk) { exit 1 }
    exit 0
  }

  $script:ReadOnly = $false
  $Temp = Join-Path ([IO.Path]::GetTempPath()) ("opencode-hop-" + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $Temp | Out-Null
  $file = Join-Path $Temp $Asset
  $sums = Join-Path $Temp 'SHA256SUMS'

  Write-Host "Downloading $Asset ($Release)..."
  try {
    Invoke-Download -Url "$Base/$Asset" -OutFile $file
    Invoke-Download -Url "$Base/SHA256SUMS" -OutFile $sums
  } catch {
    throw "could not download $Asset.`nManual download: https://github.com/$Repo/releases/latest`nAsset: $Asset`n$($_.Exception.Message)"
  }

  $expected = $null
  foreach ($line in Get-Content -Path $sums) {
    $trimmed = $line.Trim()
    if ($trimmed -match "\s+$([regex]::Escape($Asset))\s*$") {
      $expected = ($trimmed -split '\s+')[0].ToLowerInvariant()
      break
    }
  }
  if (-not $expected) { throw "SHA256SUMS has no entry for $Asset" }
  $actual = Get-Sha256 -Path $file
  if ($actual -ne $expected) {
    throw "checksum mismatch for $Asset.`n  expected: $expected`n  actual:   $actual`nThe download is incomplete or the release is broken. Try again."
  }
  $Checksum = 'OK'

  $pe = Get-PeMachine -Path $file
  if ($pe -ne $Arch) {
    throw "the downloaded file does not match this machine.`n  file:     $Asset ($pe)`n  machine:  $Machine`nThis release asset is mislabeled or corrupt; please report it."
  }
  $Format = "PE $pe"

  Get-ServiceState
  Stop-ServiceIfRunning
  Install-Binary -File $file
  Start-ServiceIfWasRunning
  Add-UserPath
  Set-Marker

  Show-Summary
  Show-Done
  exit 0
} catch {
  Write-Host ''
  Write-Host "error: $($_.Exception.Message)" -ForegroundColor Red
  if ($Asset) {
    Write-Host ''
    Write-Host "Manual download: https://github.com/$Repo/releases/latest"
    Write-Host "Asset: $Asset"
  }
  exit 1
} finally {
  if ($Temp -and (Test-Path $Temp)) {
    Remove-Item -Recurse -Force -Path $Temp -ErrorAction SilentlyContinue
  }
}
