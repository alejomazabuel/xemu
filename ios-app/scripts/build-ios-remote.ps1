[CmdletBinding()]
param(
  [string]$MacHost = "",
  [string]$MacUser = "",
  [string]$SshKeyPath = "",
  [string]$RemoteWorkspace = "",
  [string]$CloneUrl = "",
  [string]$Ref = "",
  [string]$ConfigPath = "build/ios-remote/remote-mac.json",
  [string]$OutputDirectory = "build/ios-remote/runs",
  [string]$SimDestination = "platform=iOS Simulator,name=iPhone 16,OS=latest",
  [bool]$RunDeviceBuild = $true,
  [switch]$SkipFetch,
  [switch]$SkipDownload
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

  if ([string]::IsNullOrWhiteSpace($Path)) {
    throw "Remote workspace path cannot be empty."
  }

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
    [switch]$CaptureOutput
  )

  $arguments = @(
    "-o", "StrictHostKeyChecking=accept-new"
  )

  if (-not [string]::IsNullOrWhiteSpace($KeyPath)) {
    $arguments += @("-i", $KeyPath)
  }

  $arguments += @($Target, $RemoteCommand)

  return (Invoke-ExternalCommand -Command $script:SshBinaryPath -Arguments $arguments -CaptureOutput:$CaptureOutput)
}

function Get-CurrentGitRef {
  $refResult = Invoke-ExternalCommand -Command $script:GitBinaryPath -Arguments @("branch", "--show-current") -WorkingDirectory $repoRoot -CaptureOutput
  if ($refResult.ExitCode -ne 0) {
    throw "Failed to determine the current Git branch."
  }

  $currentRef = (($refResult.Output -join [Environment]::NewLine).Trim())
  if ([string]::IsNullOrWhiteSpace($currentRef)) {
    throw "Current Git branch is empty. Pass -Ref explicitly."
  }

  return $currentRef
}

function Get-CurrentCommit {
  $commitResult = Invoke-ExternalCommand -Command $script:GitBinaryPath -Arguments @("rev-parse", "HEAD") -WorkingDirectory $repoRoot -CaptureOutput
  if ($commitResult.ExitCode -ne 0) {
    throw "Failed to determine the current Git commit."
  }

  return (($commitResult.Output -join [Environment]::NewLine).Trim())
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
$script:ScpBinaryPath = Resolve-OpenSshBinary -Name "scp"
$script:GitBinaryPath = Resolve-CommandBinary -Name "git"
$configPathAbsolute = Resolve-AbsolutePath -Path $ConfigPath -BasePath $repoRoot
$resolvedRemoteWorkspace = ""

if (Test-Path -LiteralPath $configPathAbsolute) {
  $config = Get-Content -LiteralPath $configPathAbsolute -Raw | ConvertFrom-Json

  if ([string]::IsNullOrWhiteSpace($MacHost) -and $config.mac_host) {
    $MacHost = [string]$config.mac_host
  }

  if ([string]::IsNullOrWhiteSpace($MacUser) -and $config.mac_user) {
    $MacUser = [string]$config.mac_user
  }

  if ([string]::IsNullOrWhiteSpace($SshKeyPath) -and $config.ssh_key_path) {
    $SshKeyPath = [string]$config.ssh_key_path
  }

  if ([string]::IsNullOrWhiteSpace($RemoteWorkspace) -and $config.remote_workspace) {
    $RemoteWorkspace = [string]$config.remote_workspace
  }

  if ([string]::IsNullOrWhiteSpace($CloneUrl) -and $config.clone_url) {
    $CloneUrl = [string]$config.clone_url
  }

  if ($config.remote_workspace_absolute) {
    $resolvedRemoteWorkspace = [string]$config.remote_workspace_absolute
  }
}

if ([string]::IsNullOrWhiteSpace($MacHost) -or [string]::IsNullOrWhiteSpace($MacUser)) {
  throw "Mac host and user are required. Run setup-ios-remote-mac.cmd first or pass -MacHost and -MacUser."
}

if ([string]::IsNullOrWhiteSpace($SshKeyPath)) {
  $SshKeyPath = $defaultKeyPath
}

if ([string]::IsNullOrWhiteSpace($RemoteWorkspace)) {
  $RemoteWorkspace = "~/x1box-remote-build"
}

if ([string]::IsNullOrWhiteSpace($Ref)) {
  $Ref = Get-CurrentGitRef
}

if ([string]::IsNullOrWhiteSpace($CloneUrl)) {
  $CloneUrl = Get-PreferredCloneUrl
}

$target = "$MacUser@$MacHost"
if ([string]::IsNullOrWhiteSpace($resolvedRemoteWorkspace)) {
  $remoteWorkspaceExpression = ConvertTo-RemotePathExpression -Path $RemoteWorkspace
  $resolveWorkspaceCommand = "set -euo pipefail; mkdir -p $remoteWorkspaceExpression; cd $remoteWorkspaceExpression; pwd"
  $resolvedWorkspaceResult = Invoke-SshCommand -Target $target -RemoteCommand $resolveWorkspaceCommand -KeyPath $SshKeyPath -CaptureOutput
  if ($resolvedWorkspaceResult.ExitCode -ne 0) {
    throw "Failed to resolve the remote workspace path."
  }

  $resolvedRemoteWorkspace = (($resolvedWorkspaceResult.Output -join [Environment]::NewLine).Trim())
  if ([string]::IsNullOrWhiteSpace($resolvedRemoteWorkspace)) {
    throw "The remote workspace path could not be resolved."
  }
}

$currentCommit = Get-CurrentCommit
$runTimestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$resolvedRemoteRunWorkspace = ($resolvedRemoteWorkspace.TrimEnd("/") + "/runs/" + $runTimestamp)
$outputDirectoryAbsolute = Resolve-AbsolutePath -Path $OutputDirectory -BasePath $repoRoot
$runOutputDirectory = Join-Path $outputDirectoryAbsolute $runTimestamp
New-Item -ItemType Directory -Force -Path $runOutputDirectory | Out-Null

$metadata = [ordered]@{
  started_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  mac_host = $MacHost
  mac_user = $MacUser
  remote_workspace = $resolvedRemoteWorkspace
  remote_run_workspace = $resolvedRemoteRunWorkspace
  git_ref = $Ref
  local_commit = $currentCommit
  clone_url = $CloneUrl
  simulator_destination = $SimDestination
  run_device_build = $RunDeviceBuild
}

$metadataPath = Join-Path $runOutputDirectory "run-metadata.json"
$metadata | ConvertTo-Json -Depth 4 | Set-Content -Path $metadataPath -Encoding UTF8

$warningStatus = Invoke-ExternalCommand -Command $script:GitBinaryPath -Arguments @("status", "--short") -WorkingDirectory $repoRoot -CaptureOutput
if ($warningStatus.ExitCode -eq 0) {
  $dirtyEntries = @($warningStatus.Output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if ($dirtyEntries.Count -gt 0) {
    Write-Warning "The local working tree has uncommitted changes. The remote build will only use the pushed Git ref '$Ref'."
  }
}

$remoteWorkspaceRootLiteral = Quote-BashLiteral -Value $resolvedRemoteWorkspace
$remoteRepoPathLiteral = Quote-BashLiteral -Value $resolvedRemoteRunWorkspace
$remoteRepoGitPathLiteral = Quote-BashLiteral -Value ($resolvedRemoteRunWorkspace.TrimEnd("/") + "/.git")
$cloneUrlLiteral = Quote-BashLiteral -Value $CloneUrl
$remoteRefLiteral = Quote-BashLiteral -Value $Ref
$remoteOriginRefLiteral = Quote-BashLiteral -Value ("origin/$Ref")
$runDeviceBuildValue = if ($RunDeviceBuild) { "true" } else { "false" }
$remoteBuildCommandParts = New-Object System.Collections.Generic.List[string]
$remoteBuildCommandParts.Add("set -euo pipefail")
$remoteBuildCommandParts.Add("mkdir -p $remoteWorkspaceRootLiteral")
$remoteBuildCommandParts.Add("mkdir -p $(Quote-BashLiteral -Value ($resolvedRemoteWorkspace.TrimEnd('/') + '/runs'))")
$remoteBuildCommandParts.Add("if [ -d $remoteRepoPathLiteral ]; then rm -rf $remoteRepoPathLiteral; fi")
$remoteBuildCommandParts.Add("git clone $cloneUrlLiteral $remoteRepoPathLiteral")
$remoteBuildCommandParts.Add("cd $remoteRepoPathLiteral")
if (-not $SkipFetch) {
  $remoteBuildCommandParts.Add("git fetch --all --tags --prune")
}
$remoteBuildCommandParts.Add("if git show-ref --verify --quiet $(Quote-BashLiteral -Value ("refs/remotes/origin/$Ref")); then git checkout -B $remoteRefLiteral $remoteOriginRefLiteral; else git checkout $remoteRefLiteral; fi")
$remoteBuildCommandParts.Add("git submodule update --init --recursive")
$remoteBuildCommandParts.Add("mkdir -p build/ios-remote")
$remoteBuildCommandParts.Add("python3 -m venv build/ios-remote/python-env")
$remoteBuildCommandParts.Add(". build/ios-remote/python-env/bin/activate")
$remoteBuildCommandParts.Add("python -m pip install --upgrade pip")
$remoteBuildCommandParts.Add("python -m pip install meson ninja pyyaml")
$remoteBuildCommandParts.Add("printf '%s\n' $remoteRefLiteral > build/ios-remote/last-ref.txt")
$remoteBuildCommandParts.Add("git rev-parse HEAD > build/ios-remote/last-commit.txt")
$remoteBuildCommandParts.Add("bash ios-app/scripts/build-x1box-ios-deps.sh")
$remoteBuildCommandParts.Add("export X1BOX_IOS_DEPS_ROOT=build/ios-deps/artifacts/x1box-ios-deps")
$remoteBuildCommandParts.Add("bash ios-app/scripts/build-x1box-embedded-core.sh")
$remoteBuildCommandParts.Add("bash ios-app/scripts/prepare-embedded-core-dropin.sh build/ios-embedded-core/artifacts ios-app/EmbeddedCore")
$remoteBuildCommandParts.Add("export SIM_DESTINATION=$(Quote-BashLiteral -Value $SimDestination)")
$remoteBuildCommandParts.Add("export RUN_DEVICE_BUILD=$(Quote-BashLiteral -Value $runDeviceBuildValue)")
$remoteBuildCommandParts.Add("bash ios-app/scripts/ci-build-ios.sh")
$remoteBuildCommand = ($remoteBuildCommandParts -join "; ")

Write-Host "Running remote iOS build on $target"
$buildResult = Invoke-SshCommand -Target $target -RemoteCommand $remoteBuildCommand -KeyPath $SshKeyPath
$buildSucceeded = ($buildResult.ExitCode -eq 0)

if (-not $SkipDownload) {
  Write-Host "Downloading remote artifacts to $runOutputDirectory"
  $localArtifactRoot = Join-Path $runOutputDirectory "ios-ci"
  New-Item -ItemType Directory -Force -Path $localArtifactRoot | Out-Null

  foreach ($artifactName in @("logs", "packages", "signed", "results")) {
    $remoteArtifactPath = "{0}:{1}/build/ios-ci/{2}" -f $target, $resolvedRemoteRunWorkspace, $artifactName
    $artifactResult = Invoke-ExternalCommand -Command $script:ScpBinaryPath -Arguments @("-o", "StrictHostKeyChecking=accept-new", "-i", $SshKeyPath, "-r", $remoteArtifactPath, $localArtifactRoot)
    if ($artifactResult.ExitCode -ne 0) {
      Write-Warning "Remote artifact path build/ios-ci/$artifactName was not downloaded. It may not have been produced for this run."
    }
  }

  $lastRefSource = "{0}:{1}/build/ios-remote/last-ref.txt" -f $target, $resolvedRemoteRunWorkspace
  $lastCommitSource = "{0}:{1}/build/ios-remote/last-commit.txt" -f $target, $resolvedRemoteRunWorkspace
  Invoke-ExternalCommand -Command $script:ScpBinaryPath -Arguments @("-o", "StrictHostKeyChecking=accept-new", "-i", $SshKeyPath, $lastRefSource, $runOutputDirectory) | Out-Null
  Invoke-ExternalCommand -Command $script:ScpBinaryPath -Arguments @("-o", "StrictHostKeyChecking=accept-new", "-i", $SshKeyPath, $lastCommitSource, $runOutputDirectory) | Out-Null
}

if (-not $buildSucceeded) {
  throw "The remote iOS build failed. Downloaded artifacts, if available, were placed in $runOutputDirectory."
}

Write-Host
Write-Host "Remote iOS build completed successfully."
Write-Host "Artifacts: $runOutputDirectory"
