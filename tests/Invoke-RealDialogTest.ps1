#Requires -Version 5.1
<#
.SYNOPSIS
    Manual check of the Windows security key dialog handling against the real Windows Settings app.
.DESCRIPTION
    Starts the real window (no simulation), opens the Windows security key dialog, checks that it is centered over the tool
    window while the large Settings window is hidden, takes a screenshot of the desktop and verifies that everything is
    closed again. Needs a visible, unlocked desktop and takes about 30 seconds. No key is touched, no Graph call is made.
    Exit code 0 when every check passed.
#>
[CmdletBinding()]
param([string]$WorkDirectory)

$ErrorActionPreference = 'Stop'
if (-not $WorkDirectory) { $WorkDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('passkeyprovisioner-realdialog-' + (Get-Date -Format 'yyyyMMdd-HHmmss')) }
[void][System.IO.Directory]::CreateDirectory($WorkDirectory)

$app = (Resolve-Path (Join-Path $PSScriptRoot '..\src\PasskeyProvisioner.App\Start-PasskeyProvisionerApp.ps1')).ProviderPath
$auto = (Resolve-Path (Join-Path $PSScriptRoot 'Ui\RealDialog.ps1')).ProviderPath
$out = Join-Path $WorkDirectory 'checks.json'
$config = Join-Path $WorkDirectory 'settings.json'
@{ tenantId = 'simulation.invalid'; logDirectory = (Join-Path $WorkDirectory 'logs') } | ConvertTo-Json | Set-Content -LiteralPath $config -Encoding UTF8

$env:PASSKEYPROVISIONER_UITEST_OUT = $out
$env:PASSKEYPROVISIONER_UITEST_DIR = $WorkDirectory
$env:PASSKEYPROVISIONER_UISETTINGS = Join-Path $WorkDirectory 'ui-settings.json'
try {
    $proc = Start-Process -FilePath powershell.exe -PassThru -WindowStyle Normal -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$app`"", '-Theme', 'Dark',
        '-ConfigPath', "`"$config`"", '-AutoRunScript', "`"$auto`"")
    if (-not $proc.WaitForExit(120000)) { $proc.Kill(); throw 'The dialog test did not finish within 120 seconds.' }
} finally {
    Remove-Item Env:\PASSKEYPROVISIONER_UITEST_OUT, Env:\PASSKEYPROVISIONER_UITEST_DIR, Env:\PASSKEYPROVISIONER_UISETTINGS -ErrorAction SilentlyContinue
}

if (-not (Test-Path -LiteralPath $out)) { throw "No result file ($out)." }
$checks = @(Get-Content -LiteralPath $out -Raw | ConvertFrom-Json | ForEach-Object { $_ })
foreach ($c in $checks) {
    $line = '{0} {1}' -f $(if ($c.Passed) { '[PASS]' } else { '[FAIL]' }), $c.Name
    if (-not $c.Passed -and $c.Detail) { $line += "  -> $($c.Detail)" }
    Write-Output $line
}
$failed = @($checks | Where-Object { -not $_.Passed })
Write-Output ('{0} check(s), {1} failed. Work directory: {2}' -f $checks.Count, $failed.Count, $WorkDirectory)
exit $(if ($failed.Count) { 1 } else { 0 })
