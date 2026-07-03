# Installs the Surf module for the current user.
#
# Works two ways:
#   - Run from a cloned/extracted copy of the repo: installs the local Surf folder.
#   - Run via 'irm .../install.ps1 | iex': downloads the latest release zip from GitHub.
#
# Installs into the current-user module path for whichever PowerShell edition is running,
# so it works from both Windows PowerShell 5.1 and PowerShell 7.

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
Write-Host "Type 'surf' in a new PowerShell session to start. Optional: add 'Set-Alias s surf' to your profile."
