#Requires -Version 5.1
<#
.SYNOPSIS
    Builds dist\PasskeyProvisioner.exe with ps2exe.
.DESCRIPTION
    The EXE carries the whole application (src, assets, sample config) as a zip inside its start script
    (build\Stub.template.ps1). It unpacks itself to %LOCALAPPDATA%\PasskeyProvisioner\app\<hash> on first start, so the EXE is the
    only file to hand out. Needs the ps2exe module (installed for PowerShell 7 in Documents\PowerShell\Modules).
    Run: pwsh -NoProfile -File build\Build-Exe.ps1
.PARAMETER OutPath
    Target EXE. Default: dist\PasskeyProvisioner.exe in the repository root.
#>
[CmdletBinding()]
param([string]$OutPath)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $OutPath) { $OutPath = Join-Path $root 'dist\PasskeyProvisioner.exe' }
Import-Module ps2exe -ErrorAction Stop

$coreManifest = Import-PowerShellDataFile -Path (Join-Path $root 'src\PasskeyProvisioner.Core\PasskeyProvisioner.Core.psd1')
$version = [version]$coreManifest.ModuleVersion
$fileVersion = '{0}.{1}.{2}.0' -f $version.Major, $version.Minor, [math]::Max($version.Build, 0)

# 1. Stage and zip the application
$work = Join-Path $root 'dist\work'
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
$stage = Join-Path $work 'payload'
foreach ($item in 'src', 'assets', 'config\settings.sample.json') {
    $target = Join-Path $stage $item
    [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $target))
    Copy-Item -LiteralPath (Join-Path $root $item) -Destination $target -Recurse -Force
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zipPath = Join-Path $work 'payload.zip'
[System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $zipPath, [System.IO.Compression.CompressionLevel]::Optimal, $false)
$zipBytes = [System.IO.File]::ReadAllBytes($zipPath)
$hash = ([System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($zipBytes)) -replace '-', '').Substring(0, 12).ToLower()

# 2. Fill the start script
$template = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Stub.template.ps1'))
$stub = $template.Replace('@@HASH@@', $hash).Replace('@@PAYLOAD@@', [Convert]::ToBase64String($zipBytes))
$stubPath = Join-Path $work 'PasskeyProvisioner.stub.ps1'
[System.IO.File]::WriteAllText($stubPath, $stub, (New-Object System.Text.ASCIIEncoding))

# 3. Compile
[void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $OutPath))
if (Test-Path -LiteralPath $OutPath) { Remove-Item -LiteralPath $OutPath -Force }
Invoke-ps2exe -inputFile $stubPath -outputFile $OutPath -STA -noConsole -noOutput -noError `
    -iconFile (Join-Path $root 'assets\app.ico') -title 'Passkey Provisioner' -product 'Passkey Provisioner' `
    -company 'Passkey Provisioner' -description 'Registers FIDO2 security keys in Microsoft Entra ID on behalf of users' `
    -version $fileVersion | Out-Null

if (-not (Test-Path -LiteralPath $OutPath)) { throw 'ps2exe did not produce the EXE.' }
Remove-Item -LiteralPath $work -Recurse -Force
Write-Output ('Built {0} ({1:N1} MB), version {2}, payload {3}' -f $OutPath, ((Get-Item -LiteralPath $OutPath).Length / 1MB), $fileVersion, $hash)
