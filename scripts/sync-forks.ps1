#Requires -Version 5.1
<#
.SYNOPSIS
  Run forksync locally on Windows (wraps scripts/sync-forks.sh).

.EXAMPLE
  .\scripts\sync-forks.ps1
#>
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$bashScript = Join-Path $scriptDir "sync-forks.sh"

function Find-Gh {
  $cmd = Get-Command gh -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  foreach ($path in @(
      "${env:ProgramFiles}\GitHub CLI\gh.exe",
      "${env:LOCALAPPDATA}\Programs\GitHub CLI\gh.exe",
      "${env:ProgramFiles(x86)}\GitHub CLI\gh.exe"
    )) {
    if ($path -and (Test-Path -LiteralPath $path)) { return $path }
  }
  return $null
}

function Find-GitBash {
  # Prefer Git for Windows bash. Do NOT use C:\Windows\System32\bash.exe (WSL).
  foreach ($path in @(
      "${env:ProgramFiles}\Git\bin\bash.exe",
      "${env:ProgramFiles}\Git\usr\bin\bash.exe",
      "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
      "${env:LOCALAPPDATA}\Programs\Git\bin\bash.exe"
    )) {
    if ($path -and (Test-Path -LiteralPath $path)) { return $path }
  }

  $cmd = Get-Command bash -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Source -notmatch '\\(System32|WindowsApps)\\bash\.exe$') {
    return $cmd.Source
  }
  return $null
}

$gh = Find-Gh
if (-not $gh) {
  Write-Error "gh CLI is required. Install from https://cli.github.com/ (or: winget install GitHub.cli), then fully restart Cursor and run: gh auth login"
}

# Ensure child processes (bash) can resolve `gh` even if this terminal's PATH is stale.
$ghDir = Split-Path -Parent $gh
if ($env:Path -notlike "*$ghDir*") {
  $env:Path = "$ghDir;$env:Path"
}

$bash = Find-GitBash
if (-not $bash) {
  Write-Error @"
Git Bash was not found. Install Git for Windows (https://git-scm.com/download/win), then re-run:
  .\scripts\sync-forks.ps1
Or from Git Bash:
  bash scripts/sync-forks.sh
"@
}

# Forward FORK_SYNC_TOKEN into GH_TOKEN for the bash script when set.
if (-not $env:GH_TOKEN -and $env:FORK_SYNC_TOKEN) {
  $env:GH_TOKEN = $env:FORK_SYNC_TOKEN
}

# Git Bash treats backslashes as escapes; pass a drive path with forward slashes.
$bashScriptUnix = ($bashScript -replace '\\', '/')

& $bash $bashScriptUnix @args
exit $LASTEXITCODE
