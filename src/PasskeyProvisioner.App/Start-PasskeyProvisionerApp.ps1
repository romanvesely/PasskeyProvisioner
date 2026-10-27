#Requires -Version 5.1
<#
.SYNOPSIS
    Starts the Passkey Provisioner (WPF).
.DESCRIPTION
    Registers FIDO2 security keys in Microsoft Entra ID on behalf of users, one at a time or from a CSV file.
    Runs as a standard user. Windows PowerShell 5.1 in an STA thread is required for WPF; the script restarts
    itself in STA when needed.
.PARAMETER ConfigPath
    Explicit settings.json. Defaults to config/settings.json when present, otherwise built-in defaults.
.PARAMETER InitialView
    Register, Keys or Log. For design review.
.PARAMETER InitialStep
    Step of the Register view (1-4). For design review.
.PARAMETER Theme
    System (follows the Windows app mode and changes with it), Light (Rose Pine Dawn), Dark (Rose Pine) or Default
    (the saved choice, otherwise System). Switch in the app with the button in the navigation rail or Ctrl+T.
.PARAMETER InitialGuide
    Opens the key management guide (Reset or Pin) at start. For design review.
.PARAMETER Demo
    Fills the window with fake data and starts no background services. Never talks to Microsoft Graph.
.PARAMETER Simulate
    Replaces Microsoft Graph, the key prompt and the key detection with fakes. For demonstrations and the automated
    UI test. Simulated key presence is controlled by the file passkeyprovisioner-sim-key.txt in the temp folder
    ('0' = no key).
.PARAMETER AutoRunScript
    Script that is run inside the window after start. Used by tests/Invoke-UiSimulationTest.ps1.
.PARAMETER ScreenshotPath
    Renders the window to this PNG file after start and closes it. For design review.
.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\PasskeyProvisioner.App\Start-PasskeyProvisionerApp.ps1
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [ValidateSet('Register', 'Keys', 'Log')][string]$InitialView = 'Register',
    [ValidateRange(1, 4)][int]$InitialStep = 1,
    [switch]$Demo,
    [string]$ScreenshotPath,
    [int]$ScreenshotDelayMs = 900,
    [switch]$Simulate,
    [string]$AutoRunScript,
    [ValidateSet('Default', 'System', 'Dark', 'Light')][string]$Theme = 'Default',
    [ValidateSet('None', 'Reset', 'Pin')][string]$InitialGuide = 'None'
)

$ErrorActionPreference = 'Stop'

# WPF needs an STA thread. Restart in STA when the host started in MTA.
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
    $forward = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', $PSCommandPath)
    foreach ($key in $PSBoundParameters.Keys) {
        $value = $PSBoundParameters[$key]
        if ($value -is [System.Management.Automation.SwitchParameter]) { if ($value.IsPresent) { $forward += "-$key" } }
        else { $forward += "-$key"; $forward += [string]$value }
    }
    & powershell.exe @forward
    exit $LASTEXITCODE
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$coreModulePath = Join-Path $PSScriptRoot '..\PasskeyProvisioner.Core\PasskeyProvisioner.Core.psd1'
Import-Module $coreModulePath -Force

. (Join-Path $PSScriptRoot 'Models.ps1')
. (Join-Path $PSScriptRoot 'ThemeMath.ps1')
. (Join-Path $PSScriptRoot 'Worker.ps1')
. (Join-Path $PSScriptRoot 'WindowTools.ps1')
. (Join-Path $PSScriptRoot 'WindowMath.ps1')
. (Join-Path $PSScriptRoot 'App.ps1')

Start-PasskeyProvisionerAppWindow -AppRoot $PSScriptRoot -CoreModulePath (Resolve-Path $coreModulePath).ProviderPath `
    -ConfigPath $ConfigPath -InitialView $InitialView -InitialStep $InitialStep -Demo:$Demo `
    -ScreenshotPath $ScreenshotPath -ScreenshotDelayMs $ScreenshotDelayMs -Simulate:$Simulate -AutoRunScript $AutoRunScript -Theme $Theme -InitialGuide $InitialGuide
