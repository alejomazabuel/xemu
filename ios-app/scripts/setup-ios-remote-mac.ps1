[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$MacHost,

  [Parameter(Mandatory = $true)]
  [string]$MacUser,

  [string]$CloneUrl = "",
  [string]$RemoteWorkspace = "~/x1box-remote-build",
  [string]$SshKeyPath = "",
  [string]$ConfigPath = "build/ios-remote/remote-mac.json",
  [switch]$SkipKeyInstall,
  [switch]$SkipClone
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-RepoRoot {
  return (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
}

function Resolve-AbsolutePath {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$BasePath
  )

  if ([System.IO.Path]::IsPathRooted($Path)) {
    return $Path
  }

  return [System.IO.Path]::GetFullPath((Join-Path $BasePath $Path))
}

function Quote-BashLiteral {
  param([Parameter(Mandatory = $true)][string]$Value)

  $singleQuoteEscape = "'" + '"' + "'" + '"' + "'"
  return "'" + ($Value -replace "'", $singleQuoteEscape) + "'"
}

function ConvertTo-RemotePathExpression {
  param([Parameter(Mandatory = $true)][string]$Path)

  if ($Path -eq "~") {
    return '$HOME'
  }

  if ($Path.StartsWith("~/")) {
    $suffix = $Path.Substring(2)
    if ([string]::IsNullOrWhiteSpace($suffix)) {
      return '$HOME'
    }

    return ('$HOME/' + $suffix)
  }

  return (Quote-BashLiteral -Value $Path)
}

function Resolve-OpenSshBinary {
  param([Parameter(Mandatory = $true)][string]$Name)

  $preferredPath = Join-Path $env:WINDIR ("System32\OpenSSH\{0}.exe" -f $Name)
  if (Test-Path -LiteralPath $preferredPath) {
    return $preferredPath
  }

  $commandInfo = Get-Command ("{0}.exe" -f $Name), $Name -ErrorAction SilentlyContinue |
    Where-Object { $_.Source -and ($_.Source -notlike "*\.sbx-denybin\*") } |
    Select-Object -First 1

  if (-not $commandInfo) {
    throw "Unable to resolve the OpenSSH binary for '$Name'."
  }

  return $commandInfo.Source
}

function Resolve-CommandBinary {
  param([Parameter(Mandatory = $true)][string]$Name)

  $commandInfo = Get-Command ("{0}.exe" -f $Name), $Name -ErrorAction SilentlyContinue |
    Where-Object { $_.Source } |
    Select-Object -First 1

  if (-not $commandInfo) {
    throw "Unable to resolve the binary for '$Name'."
  }

  return $commandInfo.Source
}

function ConvertTo-WindowsArgument {
  param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

  if ($Value.Length -eq 0) {
    return '""'
  }

  if ($Value -notmatch '[\s"]') {
    return $Value
  }

  $builder = New-Object System.Text.StringBuilder
  [void]$builder.Append('"')
  $backslashCount = 0

  foreach ($character in $Value.ToCharArray()) {
    if ($character -eq '\') {
      $backslashCount++
      continue
    }

    if ($character -eq '"') {
      [void]$builder.Append('\', ($backslashCount * 2) + 1)
      [void]$builder.Append('"')
      $backslashCount = 0
      continue
    }

    if ($backslashCount -gt 0) {
      [void]$builder.Append('\', $backslashCount)
      $backslashCount = 0
    }

    [void]$builder.Append($character)
  }

  if ($backslashCount -gt 0) {
    [void]$builder.Append('\', $backslashCount * 2)
  }

  [void]$builder.Append('"')
  return $builder.ToString()
}

function Invoke-ExternalCommand {
  param(
    [Parameter(Mandatory = $true)][string]$Command,
    [Parameter(Mandatory = $true)][AllowEmptyString()][string[]]$Arguments,
    [string]$WorkingDirectory = "",
    [switch]$CaptureOutput
  )

  $processStartInfo = New-Object System.Diagnostics.ProcessStartInfo
  $processStartInfo.FileName = $Command
  $processStartInfo.Arguments = (($Arguments | ForEach-Object { ConvertTo-WindowsArgument -Value $_ }) -join " ")
  $processStartInfo.UseShellExecute = $false
  $processStartInfo.RedirectStandardOutput = $true
  $processStartInfo.RedirectStandardError = $true
  $processStartInfo.CreateNoWindow = $true
  if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
    $processStartInfo.WorkingDirectory = $WorkingDirectory
  }

  $exitCode = $null
  try {
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $processStartInfo
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    $exitCode = $process.ExitCode
  } finally {
    if ($process) {
      $process.Dispose()
    }
  }

  $outputLines = @()
  if (-not [string]::IsNullOrEmpty($stdout)) {
    $outputLines += @($stdout -split "(`r`n|`n|`r)")
  }
  if (-not [string]::IsNullOrEmpty($stderr)) {
    $outputLines += @($stderr -split "(`r`n|`n|`r)")
  }

  if ($CaptureOutput) {
    return @{
      ExitCode = $exitCode
      Output = $outputLines
    }
  }

  foreach ($line in $outputLines) {
    if (-not [string]::IsNullOrWhiteSpace($line)) {
      Write-Host $line
    }
  }
  return @{
    ExitCode = $exitCode
    Output = @()
  }
}

function Invoke-SshCommand {
  param(
    [Parameter(Mandatory = $true)][string]$Target,
    [Parameter(Mandatory = $true)][string]$RemoteCommand,
    [Parameter(Mandatory = $true)][string]$KeyPath,
    [switch]$CaptureOutput,
    [switch]$AllowInteractivePassword
  )

  $arguments = @(
    "-o", "StrictHostKeyChecking=accept-new"
  )

  if (-not [string]::IsNullOrWhiteSpace($KeyPath)) {
    $arguments += @("-i", $KeyPath)
  }

  if (-not $AllowInteractivePassword) {
    $arguments += @("-o", "BatchMode=yes")
  }

  $arguments += @($Target, $RemoteCommand)

  return (Invoke-ExternalCommand -Command $script:SshBinaryPath -Arguments $arguments -CaptureOutput:$CaptureOutput)
}

function Get-PreferredCloneUrl {
  $upstreamResult = Invoke-ExternalCommand -Command $script:GitBinaryPath -Arguments @("rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}") -WorkingDirectory $repoRoot -CaptureOutput
  if ($upstreamResult.ExitCode -eq 0) {
    $upstreamRef = (($upstreamResult.Output -join [Environment]::NewLine).Trim())
    if ($upstreamRef -match "^(?<remote>[^/]+)/") {
      $remoteName = $Matches.remote
      $remoteUrlResult = Invoke-ExternalCommand -Command $script:GitBinaryPath -Arguments @("config", "--get", ("remote.{0}.url" -f $remoteName)) -WorkingDirectory $repoRoot -CaptureOutput
      if ($remoteUrlResult.ExitCode -eq 0) {
        $remoteUrl = (($remoteUrlResult.Output -join [Environment]::NewLine).Trim())
        if (-not [string]::IsNullOrWhiteSpace($remoteUrl)) {
          return $remoteUrl
        }
      }
    }
  }

  $originUrlResult = Invoke-ExternalCommand -Command $script:GitBinaryPath -Arguments @("config", "--get", "remote.origin.url") -WorkingDirectory $repoRoot -CaptureOutput
  if ($originUrlResult.ExitCode -eq 0) {
    $originUrl = (($originUrlResult.Output -join [Environment]::NewLine).Trim())
    if (-not [string]::IsNullOrWhiteSpace($originUrl)) {
      return $originUrl
    }
  }

  return ""
}

$repoRoot = Get-RepoRoot
$defaultKeyPath = Join-Path $repoRoot "build\ios-remote\keys\id_ed25519_x1box_ios_remote"
$script:SshBinaryPath = Resolve-OpenSshBinary -Name "ssh"
$script:SshKeygenBinaryPath = Resolve-OpenSshBinary -Name "ssh-keygen"
$script:GitBinaryPath = Resolve-CommandBinary -Name "git"

if ([string]::IsNullOrWhiteSpace($CloneUrl)) {
  $CloneUrl = Get-PreferredCloneUrl
}

if ([string]::IsNullOrWhiteSpace($SshKeyPath)) {
  $SshKeyPath = $defaultKeyPath
}

$configPathAbsolute = Resolve-AbsolutePath -Path $ConfigPath -BasePath $repoRoot
$configDirectory = Split-Path -Parent $configPathAbsolute
New-Item -ItemType Directory -Force -Path $configDirectory | Out-Null

$sshDirectory = Split-Path -Parent $SshKeyPath
if (-not (Test-Path -LiteralPath $sshDirectory)) {
  New-Item -ItemType Directory -Force -Path $sshDirectory | Out-Null
}

if (-not (Test-Path -LiteralPath $SshKeyPath)) {
  Write-Host "Creating SSH key at $SshKeyPath"
  $keygenResult = Invoke-ExternalCommand -Command $script:SshKeygenBinaryPath -Arguments @("-q", "-t", "ed25519", "-f", $SshKeyPath, "-N", '""', "-C", "x1box-ios-remote")
  if ($keygenResult.ExitCode -ne 0 -and -not (Test-Path -LiteralPath $SshKeyPath)) {
    throw "Failed to create the SSH key at $SshKeyPath."
  }

  if ($keygenResult.ExitCode -ne 0) {
    Write-Warning "ssh-keygen returned exit code $($keygenResult.ExitCode), but the private key exists. Continuing with a derived public key."
  }
} else {
  Write-Host "Using existing SSH key at $SshKeyPath"
}

$publicKeyPath = "$SshKeyPath.authorized"
$publicKeyResult = Invoke-ExternalCommand -Command $script:SshKeygenBinaryPath -Arguments @("-y", "-f", $SshKeyPath) -CaptureOutput
if ($publicKeyResult.ExitCode -ne 0) {
  throw "Failed to derive the SSH public key from $SshKeyPath."
}

$publicKeyContent = (($publicKeyResult.Output -join [Environment]::NewLine).Trim())
if ([string]::IsNullOrWhiteSpace($publicKeyContent)) {
  throw "The derived SSH public key is empty for $SshKeyPath."
}
Set-Content -LiteralPath $publicKeyPath -Value ($publicKeyContent + [Environment]::NewLine) -Encoding ascii

$target = "$MacUser@$MacHost"

if (-not $SkipKeyInstall) {
  Write-Host "Installing the SSH public key on $target"

  $installCommand = 'set -euo pipefail; umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; key=$(cat); if ! grep -qxF "$key" ~/.ssh/authorized_keys; then printf ''%s\n'' "$key" >> ~/.ssh/authorized_keys; fi'

  $sshInstallArgs = @(
    "-o", "StrictHostKeyChecking=accept-new",
    $target,
    $installCommand
  )

  $publicKeyContent | & $script:SshBinaryPath @sshInstallArgs
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to install the SSH public key on $target."
  }
}

Write-Host "Validating passwordless SSH access"
$validationResult = Invoke-SshCommand -Target $target -RemoteCommand "printf ready" -KeyPath $SshKeyPath -CaptureOutput
if ($validationResult.ExitCode -ne 0 -or (($validationResult.Output -join "").Trim() -ne "ready")) {
  throw "Passwordless SSH validation failed for $target."
}

$remoteWorkspaceExpression = ConvertTo-RemotePathExpression -Path $RemoteWorkspace
$resolveWorkspaceCommand = "set -euo pipefail; mkdir -p $remoteWorkspaceExpression; cd $remoteWorkspaceExpression; pwd"
$resolvedWorkspaceResult = Invoke-SshCommand -Target $target -RemoteCommand $resolveWorkspaceCommand -KeyPath $SshKeyPath -CaptureOutput
if ($resolvedWorkspaceResult.ExitCode -ne 0) {
  throw "Failed to create or resolve the remote workspace path '$RemoteWorkspace'."
}

$resolvedRemoteWorkspace = (($resolvedWorkspaceResult.Output -join [Environment]::NewLine).Trim())
if ([string]::IsNullOrWhiteSpace($resolvedRemoteWorkspace)) {
  throw "The remote workspace path could not be resolved."
}

if (-not $SkipClone -and -not [string]::IsNullOrWhiteSpace($CloneUrl)) {
  Write-Host "Preparing the remote Git checkout in $resolvedRemoteWorkspace"
  $remoteGitDirectory = ($resolvedRemoteWorkspace.TrimEnd("/") + "/.git")
  $cloneCommand = @(
    "set -euo pipefail",
    "if [ ! -d $(Quote-BashLiteral -Value $remoteGitDirectory) ]; then git clone $(Quote-BashLiteral -Value $CloneUrl) $(Quote-BashLiteral -Value $resolvedRemoteWorkspace); fi",
    "git -C $(Quote-BashLiteral -Value $resolvedRemoteWorkspace) remote -v"
  ) -join "; "
  $cloneResult = Invoke-SshCommand -Target $target -RemoteCommand $cloneCommand -KeyPath $SshKeyPath
  if ($cloneResult.ExitCode -ne 0) {
    throw "Failed to prepare the remote Git checkout."
  }
}

$config = [ordered]@{
  mac_host = $MacHost
  mac_user = $MacUser
  ssh_key_path = $SshKeyPath
  remote_workspace = $RemoteWorkspace
  remote_workspace_absolute = $resolvedRemoteWorkspace
  clone_url = $CloneUrl
  updated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
}

$config | ConvertTo-Json -Depth 4 | Set-Content -Path $configPathAbsolute -Encoding UTF8

Write-Host
Write-Host "Remote macOS setup is ready."
Write-Host "Config saved to: $configPathAbsolute"
Write-Host "Remote workspace: $resolvedRemoteWorkspace"
Write-Host
Write-Host "Next command:"
Write-Host ".\ios-app\scripts\build-ios-remote.cmd -Ref codex/ios-reactive-workflow"
