# Installs the Surf module for the current user.
#
# Works two ways:
#   - Run from a cloned/extracted copy of the repo: installs the local Surf folder.
#   - Run via 'irm .../install.ps1 | iex': downloads the latest release zip from GitHub.
#
# Installs into the current-user module path for whichever PowerShell edition is running,
# so it works from both Windows PowerShell 5.1 and PowerShell 7.
#
# Offers to add "Set-Alias s surf" to your profile; use -Alias or -NoAlias to skip the prompt.

param(
    [switch]$Alias,     # add the 's' alias to your profile without asking
    [switch]$NoAlias    # never touch the profile
)

$ErrorActionPreference = 'Stop'

$Repo = 'RobertScholey98/surf'

$docs = [Environment]::GetFolderPath('MyDocuments')
$moduleRoot = if ($PSVersionTable.PSEdition -eq 'Core') { Join-Path $docs 'PowerShell\Modules' }
              else { Join-Path $docs 'WindowsPowerShell\Modules' }
$dest = Join-Path $moduleRoot 'Surf'

$localModule = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'Surf' } else { $null }

if ($localModule -and (Test-Path (Join-Path $localModule 'Surf.psd1'))) {
    Write-Host "Installing Surf from local copy: $localModule"
    New-Item -ItemType Directory -Force -Path $moduleRoot | Out-Null
    if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
    Copy-Item -Recurse -Force $localModule $dest
} else {
    if ($Repo -like '<*') { throw "install.ps1: repository not configured yet (edit `$Repo at the top of this script)." }
    Write-Host "Downloading latest Surf release from github.com/$Repo ..."
    $release = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest"
    $asset = $release.assets | Where-Object { $_.name -like 'Surf*.zip' } | Select-Object -First 1
    if (-not $asset) { throw "No Surf*.zip asset found on the latest release." }
    $tmp = Join-Path $env:TEMP "surf-install-$([IO.Path]::GetRandomFileName())"
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $zip = Join-Path $tmp $asset.name
        Invoke-WebRequest $asset.browser_download_url -OutFile $zip
        Expand-Archive $zip -DestinationPath $tmp
        $src = Join-Path $tmp 'Surf'
        if (-not (Test-Path (Join-Path $src 'Surf.psd1'))) { throw "Unexpected zip layout: no Surf\Surf.psd1 inside." }
        New-Item -ItemType Directory -Force -Path $moduleRoot | Out-Null
        if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
        Copy-Item -Recurse -Force $src $dest
    } finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
}

Get-ChildItem -Recurse $dest | Unblock-File -ErrorAction SilentlyContinue

Write-Host "Surf installed to $dest" -ForegroundColor Green

# ---- optional 's' shorthand alias ---------------------------------------
$wantAlias = $false
if ($Alias) { $wantAlias = $true }
elseif (-not $NoAlias) {
    # only prompt when someone can actually answer
    $nonInteractive = [Environment]::GetCommandLineArgs() -contains '-NonInteractive'
    if (-not $nonInteractive) {
        $answer = Read-Host "Add 's' as a shorthand alias for surf in your PowerShell profile? (y/n)"
        $wantAlias = $answer -match '^y'
    }
}

$aliasAdded = $false
if ($wantAlias) {
    $aliasLine = 'Set-Alias -Name s -Value surf'
    $existingProfile = if (Test-Path $PROFILE) { Get-Content $PROFILE -Raw } else { '' }
    if ($existingProfile -match '(?m)^\s*Set-Alias\s+(-Name\s+)?s\b') {
        Write-Host "Your profile already defines an 's' alias - left as is."
        $aliasAdded = $true
    } else {
        $existingCmd = Get-Command s -ErrorAction SilentlyContinue
        if ($existingCmd -and $existingCmd.Definition -ne 'surf') {
            Write-Host "Skipped the alias: 's' already means '$($existingCmd.Definition)' in your setup." -ForegroundColor Yellow
        } else {
            $profileDir = Split-Path -Parent $PROFILE
            if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Force -Path $profileDir | Out-Null }
            Add-Content -Path $PROFILE -Value $aliasLine
            Write-Host "Added '$aliasLine' to $PROFILE" -ForegroundColor Green
            $aliasAdded = $true
        }
    }
}

if ($aliasAdded) { Write-Host "Type 'surf' (or 's') in a new PowerShell session to start." }
else { Write-Host "Type 'surf' in a new PowerShell session to start. Optional: add 'Set-Alias s surf' to your profile." }
