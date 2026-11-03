#Requires -Version 5.1
<#
.SYNOPSIS
    Builds the self-contained installer script dist\installer\<version>\Install-PasskeyProvisioner.ps1 for Intune / Robopack.
.DESCRIPTION
    Embeds the built EXE (build\Build-Exe.ps1 first) and an optional settings.json into
    packaging\Install-PasskeyProvisioner.template.ps1. Organisation-specific values stay out of the repository:
    packaging\package.local.json ({ "targetDir": "..." }) and packaging\settings.local.json are gitignored.
    Run: powershell.exe -NoProfile -File build\Build-Installer.ps1
.PARAMETER ExePath
    Built EXE. Default: dist\PasskeyProvisioner.exe.
.PARAMETER TargetDir
    Default install folder written into the script. Default: targetDir from packaging\package.local.json, else
    C:\Program Files\PasskeyProvisioner.
.PARAMETER SettingsPath
    settings.json to install next to the EXE. Default: packaging\settings.local.json when it exists, else none.
.PARAMETER OutDir
    Output folder. Default: dist\installer\<version>.
#>
[CmdletBinding()]
param([string]$ExePath, [string]$TargetDir, [string]$SettingsPath, [string]$OutDir)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $ExePath) { $ExePath = Join-Path $root 'dist\PasskeyProvisioner.exe' }
if (-not (Test-Path -LiteralPath $ExePath)) { throw "EXE not found: $ExePath (run build\Build-Exe.ps1 first)" }

$localConfig = Join-Path $root 'packaging\package.local.json'
if (-not $TargetDir -and (Test-Path -LiteralPath $localConfig)) {
    $TargetDir = (Get-Content -LiteralPath $localConfig -Raw | ConvertFrom-Json).targetDir
}
if (-not $TargetDir) { $TargetDir = 'C:\Program Files\PasskeyProvisioner' }
if (-not $SettingsPath) {
    $candidate = Join-Path $root 'packaging\settings.local.json'
    if (Test-Path -LiteralPath $candidate) { $SettingsPath = $candidate }
}
if ($SettingsPath) { $null = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json }   # fail early on broken JSON

$coreManifest = Import-PowerShellDataFile -Path (Join-Path $root 'src\PasskeyProvisioner.Core\PasskeyProvisioner.Core.psd1')
$version = [version]$coreManifest.ModuleVersion
$fileVersion = (Get-Item -LiteralPath $ExePath).VersionInfo.FileVersion
$expected = '{0}.{1}.{2}.0' -f $version.Major, $version.Minor, [math]::Max($version.Build, 0)
if ($fileVersion -ne $expected) { throw "EXE file version $fileVersion does not match the module version $expected. Rebuild the EXE." }

$settingsBase64 = ''
if ($SettingsPath) { $settingsBase64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($SettingsPath)) }
$template = [System.IO.File]::ReadAllText((Join-Path $root 'packaging\Install-PasskeyProvisioner.template.ps1'))
$script = $template.Replace('@@VERSION@@', $fileVersion).Replace('@@TARGETDIR@@', $TargetDir.Replace("'", "''")).
    Replace('@@SETTINGS@@', $settingsBase64).Replace('@@EXE@@', [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($ExePath)))

if (-not $OutDir) { $OutDir = Join-Path $root ('dist\installer\' + $fileVersion) }
[void][System.IO.Directory]::CreateDirectory($OutDir)
$outPath = Join-Path $OutDir 'Install-PasskeyProvisioner.ps1'
[System.IO.File]::WriteAllText($outPath, $script, (New-Object System.Text.ASCIIEncoding))
$settingsText = if ($SettingsPath) { 'settings ' + $SettingsPath } else { 'no settings.json' }
Write-Output ('Built {0} (version {1}, target {2}, {3})' -f $outPath, $fileVersion, $TargetDir, $settingsText)
