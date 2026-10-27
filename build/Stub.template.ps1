# Start script of Passkey Provisioner.exe (compiled with ps2exe by build\Build-Exe.ps1). ASCII only.
#
# The EXE contains the whole application as a zip. On first start (and after every update) it is unpacked to
# %LOCALAPPDATA%\PasskeyProvisioner\app\<hash>, then the normal start script runs from there. Nothing needs to be installed
# next to the EXE; an optional settings.json next to the EXE is used as configuration.

$ErrorActionPreference = 'Stop'
$WarningPreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class StubWin {
    [DllImport("kernel32.dll")] public static extern bool AllocConsole();
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
}
'@

$payload = '@@PAYLOAD@@'   # base64 of the application zip, filled in by build\Build-Exe.ps1

function Show-StartupError([string]$Text) {
    try {
        $logDir = Join-Path $env:LOCALAPPDATA 'PasskeyProvisioner'
        [void][System.IO.Directory]::CreateDirectory($logDir)
        Add-Content -LiteralPath (Join-Path $logDir 'startup-error.log') -Value ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Text)
    } catch { $null = $_ }
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show($Text, 'Passkey Provisioner', 'OK', 'Error')
}

try {
    # Only the Windows PowerShell 5.1 module locations: a start from a PowerShell 7 terminal would otherwise pass on its own
    # (incompatible) module path and the built-in modules could not be loaded.
    $env:PSModulePath = @(
        (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules'),
        (Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'),
        (Join-Path $PSHOME 'Modules')) -join ';'

    # The Microsoft sign-in (Connect-MgGraph) hangs its window on the console window of the process and fails with "A window
    # handle must be configured" when there is none. A GUI-only EXE has no console, so create one and hide it at once.
    if ([StubWin]::GetConsoleWindow() -eq [IntPtr]::Zero) {
        [void][StubWin]::AllocConsole()
        $consoleWindow = [StubWin]::GetConsoleWindow()
        if ($consoleWindow -ne [IntPtr]::Zero) { [void][StubWin]::ShowWindow($consoleWindow, 0) }
    }

    $appBase = Join-Path $env:LOCALAPPDATA 'PasskeyProvisioner\app'
    $appDir = Join-Path $appBase '@@HASH@@'
    if (-not (Test-Path -LiteralPath (Join-Path $appDir '.complete'))) {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [void][System.IO.Directory]::CreateDirectory($appBase)
        $temp = Join-Path $appBase ('unpack-' + [guid]::NewGuid().ToString('N'))
        $zip = $temp + '.zip'
        [System.IO.File]::WriteAllBytes($zip, [Convert]::FromBase64String($payload))
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $temp)
        Remove-Item -LiteralPath $zip -Force
        Set-Content -LiteralPath (Join-Path $temp '.complete') -Value '1'
        try { [System.IO.Directory]::Move($temp, $appDir) } catch { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
        # Remove older versions (best effort; one may still be running).
        Get-ChildItem -LiteralPath $appBase -Directory | Where-Object { $_.Name -ne '@@HASH@@' } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # Command line: -Name value pairs and -Switch flags become the parameters of the start script.
    $startArgs = @{}
    for ($i = 0; $i -lt $args.Count; $i++) {
        $a = [string]$args[$i]
        if ($a -notmatch '^-') { continue }
        $name = $a.TrimStart('-')
        # ps2exe hands a switch over as a '-Name' string followed by a boolean $true.
        if (($i + 1) -lt $args.Count -and $args[$i + 1] -is [bool]) { $startArgs[$name] = [bool]$args[$i + 1]; $i++ }
        elseif (($i + 1) -lt $args.Count -and ([string]$args[$i + 1]) -notmatch '^-') { $startArgs[$name] = [string]$args[$i + 1]; $i++ }
        else { $startArgs[$name] = $true }
    }
    if (-not $startArgs.ContainsKey('ConfigPath')) {
        $exeDir = Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
        $candidate = Join-Path $exeDir 'settings.json'
        if (Test-Path -LiteralPath $candidate) { $startArgs['ConfigPath'] = $candidate }
    }

    try { Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force -ErrorAction Stop } catch { $null = $_ }
    & (Join-Path $appDir 'src\PasskeyProvisioner.App\Start-PasskeyProvisionerApp.ps1') @startArgs
} catch {
    Show-StartupError ("Passkey Provisioner could not start.`n`n" + $_.Exception.Message + "`n" + $_.ScriptStackTrace)
    exit 1
}
exit 0
