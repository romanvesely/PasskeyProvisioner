[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Internal UI helper functions, not cmdlets')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Test doubles must live in the global scope of the runspace so the Core module finds them')]
param()

# Simulation mode: replaces Microsoft Graph, the WebAuthn prompt and the key detection with in-memory fakes.
# Used by the automated UI test and for demonstrations without hardware or a tenant. Loaded into the worker and the
# detector runspace by Start-PasskeyProvisionerApp.ps1 -Simulate. Nothing here talks to the network.
#
# Simulated key presence is controlled by a file: content '0' = no key, anything else (or no file) = key present.

$global:SimKeyFile = Join-Path ([System.IO.Path]::GetTempPath()) 'passkeyprovisioner-sim-key.txt'
$global:SimStore   = @{}

function global:Get-SimUserKey {
    param([string]$Upn)
    if (-not $global:SimStore.ContainsKey($Upn)) {
        $list = New-Object System.Collections.ArrayList
        if ($Upn -like 'ben.schulz@*') {
            # An old registration under the legacy display name.
            [void]$list.Add([pscustomobject]@{ Id = 'legacy-1'; DisplayName = 'T2F2-TypeC 0123456782'; CreatedDateTime = [datetime]'2026-03-02T09:12:00'; Model = 'T2F2-TypeC' })
        }
        $global:SimStore[$Upn] = $list
    }
    return $global:SimStore[$Upn]
}

function global:Connect-MgGraph {
    param($Scopes, $TenantId, [switch]$NoWelcome, $ErrorAction)
    $null = $Scopes, $TenantId, $NoWelcome, $ErrorAction
    Start-Sleep -Milliseconds 800
}

function global:Disconnect-MgGraph {
    param($ErrorAction)
    $null = $ErrorAction
}

function global:Get-MgContext {
    [pscustomobject]@{ Account = 'sim.admin@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' }
}

function global:Get-MgUserAuthenticationFido2Method {
    param($UserId, $ErrorAction)
    $null = $ErrorAction
    Start-Sleep -Milliseconds 250
    if ($UserId -like 'carla.nowak@*') { throw 'Request Authorization failed (accessDenied) - HTTP 403 Forbidden' }
    return @(Get-SimUserKey -Upn $UserId)
}

function global:Get-MgBetaUserAuthenticationFido2Method {
    param($UserId, $ErrorAction)
    Get-MgUserAuthenticationFido2Method -UserId $UserId -ErrorAction $ErrorAction
}

function global:Remove-MgUserAuthenticationFido2Method {
    param($UserId, $Fido2AuthenticationMethodId, $ErrorAction)
    $null = $ErrorAction
    Start-Sleep -Milliseconds 250
    $list = Get-SimUserKey -Upn $UserId
    $hit = $null
    foreach ($k in $list) { if ($k.Id -eq $Fido2AuthenticationMethodId) { $hit = $k } }
    if (-not $hit) { throw "Resource not found: $Fido2AuthenticationMethodId" }
    $global:SimStore[$UserId].Remove($hit)
}

function global:Remove-MgBetaUserAuthenticationFido2Method {
    param($UserId, $Fido2AuthenticationMethodId, $ErrorAction)
    Remove-MgUserAuthenticationFido2Method -UserId $UserId -Fido2AuthenticationMethodId $Fido2AuthenticationMethodId -ErrorAction $ErrorAction
}

function global:Get-PasskeyRegistrationOptions {
    param($UserId, $ErrorAction)
    $null = $UserId, $ErrorAction
    'simulated-options'
}

function global:New-Passkey {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)]$Options)
    process {
        $null = $Options
        Start-Sleep -Seconds 2   # the touch
        [pscustomobject]@{ Id = [byte[]](1..32); Response = '{"clientDataJSON":"c2ltdWxhdGVk","attestationObject":"c2ltdWxhdGVk"}' }
    }
}

function global:Invoke-MgGraphRequest {
    param($Uri, $Method, $Body, $ContentType, $ErrorAction)
    $null = $Method, $ContentType, $ErrorAction
    Start-Sleep -Milliseconds 300
    $upn = [System.Uri]::UnescapeDataString(([regex]::Match($Uri, '/users/([^/]+)/')).Groups[1].Value)
    $parsed = $Body | ConvertFrom-Json
    $key = [pscustomobject]@{ Id = ('sim-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); DisplayName = [string]$parsed.displayName; CreatedDateTime = (Get-Date); Model = 'Simulated' }
    [void](Get-SimUserKey -Upn $upn)   # makes sure the user exists in the store
    [void]$global:SimStore[$upn].Add($key)
    [pscustomobject]@{ id = $key.Id; displayName = $key.DisplayName }
}

function global:Get-FidoKeyDevice {
    $present = $true
    if (Test-Path -LiteralPath $global:SimKeyFile) { $present = ((Get-Content -LiteralPath $global:SimKeyFile -Raw).Trim() -ne '0') }
    if ($present) { [pscustomobject]@{ Detected = $true; Name = 'Simulated FIDO key'; VID = '096E'; PID = '0858'; InstanceId = 'simulated' } }
    else { [pscustomobject]@{ Detected = $false; Name = ''; VID = ''; PID = ''; InstanceId = '' } }
}

function global:Get-FidoHidDevice {
    @([pscustomobject]@{ Detected = $true; Name = 'Simulated FIDO key'; VID = '096E'; PID = '0858'; InstanceId = 'simulated' })
}
