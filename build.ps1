# Builds a release zip (dist\Surf-<version>.zip) for attaching to a GitHub release.
$ErrorActionPreference = 'Stop'

$manifest = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'Surf\Surf.psd1')
$version = $manifest.ModuleVersion
$dist = Join-Path $PSScriptRoot 'dist'
New-Item -ItemType Directory -Force -Path $dist | Out-Null

$zip = Join-Path $dist "Surf-$version.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $PSScriptRoot 'Surf') -DestinationPath $zip

Write-Host "Built $zip" -ForegroundColor Green
