#Requires -Version 5.1
<#
.SYNOPSIS
    Runs the GUI end to end in simulation mode and reports the checks of tests/Ui/AutoRun.ps1.
.DESCRIPTION
    Starts the real window (it must be visible: a minimized window never renders) with fake Graph, fake key prompt and a fake key that is "pulled and re-inserted" through
    a file. Takes about 40 seconds. Exit code 0 when every check passed, 1 otherwise.
    Screenshots of the key swap wait and the results page are saved next to the log in the work directory.
.PARAMETER WorkDirectory
    Folder for the temporary CSV, result file, log and screenshots. Defaults to a new folder in the temp directory.
.PARAMETER ExePath
    Run the compiled dist\PasskeyProvisioner.exe instead of the script (proves that the EXE behaves like the script).
#>
[CmdletBinding()]
param(
    [string]$WorkDirectory,
    [string]$ExePath
)

$ErrorActionPreference = 'Stop'
if (-not $WorkDirectory) { $WorkDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('passkeyprovisioner-uitest-' + (Get-Date -Format 'yyyyMMdd-HHmmss')) }
[void][System.IO.Directory]::CreateDirectory($WorkDirectory)

$app = (Resolve-Path (Join-Path $PSScriptRoot '..\src\PasskeyProvisioner.App\Start-PasskeyProvisionerApp.ps1')).ProviderPath
$auto = (Resolve-Path (Join-Path $PSScriptRoot 'Ui\AutoRun.ps1')).ProviderPath
$out = Join-Path $WorkDirectory 'checks.json'
$config = Join-Path $WorkDirectory 'settings.json'
@{ tenantId = 'simulation.invalid'; logDirectory = (Join-Path $WorkDirectory 'logs') } | ConvertTo-Json | Set-Content -LiteralPath $config -Encoding UTF8

$env:PASSKEYPROVISIONER_UITEST_OUT = $out
$env:PASSKEYPROVISIONER_UITEST_DIR = $WorkDirectory
$env:PASSKEYPROVISIONER_UISETTINGS = Join-Path $WorkDirectory 'ui-settings.json'   # never touch the real user settings
try {
    if ($ExePath) {
        $proc = Start-Process -FilePath (Resolve-Path $ExePath).ProviderPath -PassThru -ArgumentList @(
            '-Simulate', '-Theme', 'Dark', '-ConfigPath', "`"$config`"", '-AutoRunScript', "`"$auto`"")
    } else {
        $proc = Start-Process -FilePath powershell.exe -PassThru -WindowStyle Normal -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$app`"", '-Simulate', '-Theme', 'Dark',
            '-ConfigPath', "`"$config`"", '-AutoRunScript', "`"$auto`"")
    }
    if (-not $proc.WaitForExit(180000)) {
        $proc.Kill()
        throw 'The UI simulation did not finish within 180 seconds.'
    }
} finally {
    Remove-Item Env:\PASSKEYPROVISIONER_UITEST_OUT, Env:\PASSKEYPROVISIONER_UITEST_DIR, Env:\PASSKEYPROVISIONER_UISETTINGS -ErrorAction SilentlyContinue
}

if (-not (Test-Path -LiteralPath $out)) { throw "The simulation produced no result file ($out). Start the app by hand with -Simulate to see the error." }
# Windows PowerShell 5.1 does not unroll a JSON array on its own; the extra pipeline does.
$checks = @(Get-Content -LiteralPath $out -Raw | ConvertFrom-Json | ForEach-Object { $_ })
foreach ($c in $checks) {
    $mark = if ($c.Passed) { '[PASS]' } else { '[FAIL]' }
    $line = '{0} {1}' -f $mark, $c.Name
    if (-not $c.Passed -and $c.Detail) { $line += "  -> $($c.Detail)" }
    Write-Output $line
}
$failed = @($checks | Where-Object { -not $_.Passed })
Write-Output ('{0} check(s), {1} failed. Work directory: {2}' -f $checks.Count, $failed.Count, $WorkDirectory)
exit $(if ($failed.Count) { 1 } else { 0 })
