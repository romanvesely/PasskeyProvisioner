#Requires -Version 5.1
<#
.SYNOPSIS
    Smoke test for the module pins: imports the pinned versions in a fresh powershell.exe process and reports the
    loaded module and assembly versions. Exit code 1 on any failure.
.DESCRIPTION
    Run this before changing a pin (Phase 5) and after installing modules on a new machine.
    -Candidate tests a different version set without touching the configuration, for example:
    -Candidate @{ 'DSInternals.Passkeys' = '3.4.0' }
#>
[CmdletBinding()]
param(
    [hashtable]$Candidate
)

Import-Module (Join-Path $PSScriptRoot '..\src\PasskeyProvisioner.Core\PasskeyProvisioner.Core.psd1') -Force
$pins = [ordered]@{}
foreach ($entry in (Get-PasskeyProvisionerConfig).activeModules.GetEnumerator()) { $pins[$entry.Key] = $entry.Value }
if ($Candidate) { foreach ($k in $Candidate.Keys) { $pins[$k] = $Candidate[$k] } }

$childScript = Join-Path ([IO.Path]::GetTempPath()) ("passkeyprovisioner-matrix-{0}.ps1" -f [guid]::NewGuid().ToString('N'))
@'
$ErrorActionPreference = 'Stop'
$out = @()
try {
    # Windows PowerShell 5.1 does not unroll a JSON array on its own; the extra pipeline does.
    foreach ($p in ($env:PASSKEYPROVISIONER_PINS | ConvertFrom-Json | ForEach-Object { $_ })) {
        Import-Module -Name $p.Name -RequiredVersion $p.Version
        $m = Get-Module -Name $p.Name
        $out += [pscustomobject]@{ Module = $p.Name; Required = $p.Version; Loaded = "$($m.Version)"; Ok = ("$($m.Version)" -eq $p.Version) }
    }
    $asm = [AppDomain]::CurrentDomain.GetAssemblies() |
           Where-Object { $_.GetName().Name -match '^(Microsoft\.Graph|DSInternals)' } |
           ForEach-Object { [pscustomobject]@{ Assembly = $_.GetName().Name; Version = "$($_.GetName().Version)" } }
    [pscustomobject]@{ Modules = $out; Assemblies = @($asm); Error = $null } | ConvertTo-Json -Depth 4
} catch {
    [pscustomobject]@{ Modules = $out; Assemblies = @(); Error = "$_" } | ConvertTo-Json -Depth 4
}
'@ | Set-Content -LiteralPath $childScript -Encoding ASCII

try {
    $list = @(foreach ($entry in $pins.GetEnumerator()) { [pscustomobject]@{ Name = $entry.Key; Version = $entry.Value } })
    $env:PASSKEYPROVISIONER_PINS = ConvertTo-Json -InputObject $list -Compress
    $raw = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $childScript 2>&1
} finally {
    Remove-Item -LiteralPath $childScript -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\PASSKEYPROVISIONER_PINS -ErrorAction SilentlyContinue
}

$text = ($raw | Out-String)
try {
    $res = $text | ConvertFrom-Json
} catch {
    Write-Error "Child process returned no parsable result:`n$text"
    exit 1
}

$res.Modules | Format-Table -AutoSize | Out-String | Write-Output
if ($res.Assemblies) { $res.Assemblies | Sort-Object Assembly | Format-Table -AutoSize | Out-String | Write-Output }
$bad = @($res.Modules | Where-Object { -not $_.Ok })
if ($res.Error -or $bad.Count -gt 0) {
    Write-Error "Module matrix test FAILED. $($res.Error)"
    exit 1
}
Write-Output 'Module matrix test passed.'
exit 0
