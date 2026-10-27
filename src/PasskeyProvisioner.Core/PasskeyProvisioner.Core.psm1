#Requires -Version 5.1
<#
PasskeyProvisioner.Core - enrollment logic without any UI code.

The enrollment path (module pins, manual Graph body, Base64Url id, POST to the
fido2Methods endpoint) was verified live (201 Created, 2026-08-18). Do not change it
without a live test, see docs/LIVE-TEST.md.
#>

Set-StrictMode -Version 2.0

$script:ModuleRoot  = $PSScriptRoot
$script:LogSink     = $null
$script:LogFile     = $null
$script:ConfigCache = @{}
$script:GraphScope  = 'UserAuthenticationMethod.ReadWrite.All'

#region Configuration

function Get-PasskeyProvisionerDefaultConfig {
    [ordered]@{
        tenantId                  = ''
        displayNamePrefix         = 'FIDO SECURITY KEY'
        legacyDisplayNamePrefixes = @('T2F2-TypeC')
        graphApiVersion           = 'v1.0'
        modules                   = [ordered]@{
            'Microsoft.Graph.Authentication'        = '2.39.0'
            'Microsoft.Graph.Identity.SignIns'      = '2.39.0'
            'Microsoft.Graph.Beta.Identity.SignIns' = '2.39.0'
            'DSInternals.Passkeys'                  = '3.2.0'
        }
        logDirectory              = '%LOCALAPPDATA%\PasskeyProvisioner\logs'
        serialPattern             = ''
        centerPopupWindows        = $true
    }
}

function Get-PasskeyProvisionerConfig {
    <#
    .SYNOPSIS
        Loads settings.json (if present) and merges it over the built-in defaults.
    .DESCRIPTION
        The result has a derived property activeModules: the pinned modules that are actually installed and imported
        for the configured graphApiVersion. 'beta' needs Microsoft.Graph.Beta.Identity.SignIns, 'v1.0' needs
        Microsoft.Graph.Identity.SignIns instead.
    .PARAMETER Path
        Explicit settings file. Must exist. Without it, config/settings.json next to the repo root is used when present.
    .PARAMETER Refresh
        Ignore the cached result.
    #>
    [CmdletBinding()]
    param(
        [string]$Path,
        [switch]$Refresh
    )

    $explicit = [bool]$Path
    if (-not $Path) {
        $Path = Join-Path $script:ModuleRoot '..\..\config\settings.json'
    }
    $key = if (Test-Path -LiteralPath $Path) { (Resolve-Path -LiteralPath $Path).ProviderPath } else { '<defaults>' }
    if ($explicit -and $key -eq '<defaults>') {
        throw "Configuration file not found: $Path"
    }
    if (-not $Refresh -and $script:ConfigCache.ContainsKey($key)) {
        return $script:ConfigCache[$key]
    }

    $cfg = Get-PasskeyProvisionerDefaultConfig
    if ($key -ne '<defaults>') {
        try {
            $json = Get-Content -LiteralPath $key -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            throw "Configuration file '$key' is not valid JSON: $($_.Exception.Message)"
        }
        foreach ($prop in $json.PSObject.Properties) {
            if ($prop.Name -eq 'modules') {
                foreach ($m in $prop.Value.PSObject.Properties) { $cfg.modules[$m.Name] = [string]$m.Value }
            } elseif ($cfg.Contains($prop.Name)) {
                $cfg[$prop.Name] = $prop.Value
            }
        }
    }
    if ($cfg.graphApiVersion -notin 'beta', 'v1.0') {
        throw "Invalid graphApiVersion '$($cfg.graphApiVersion)' in configuration. Allowed values: 'beta', 'v1.0'."
    }
    $cfg.logDirectory = [Environment]::ExpandEnvironmentVariables([string]$cfg.logDirectory)
    $cfg.legacyDisplayNamePrefixes = @($cfg.legacyDisplayNamePrefixes)

    $signInsModule = if ($cfg.graphApiVersion -eq 'beta') { 'Microsoft.Graph.Beta.Identity.SignIns' } else { 'Microsoft.Graph.Identity.SignIns' }
    $active = [ordered]@{}
    foreach ($name in 'Microsoft.Graph.Authentication', $signInsModule, 'DSInternals.Passkeys') {
        if (-not $cfg.modules.Contains($name)) { throw "No version pin for required module '$name' in the configuration." }
        $active[$name] = $cfg.modules[$name]
    }
    $cfg.activeModules = $active

    $result = [pscustomobject]$cfg
    $script:ConfigCache[$key] = $result
    return $result
}

#endregion

#region Logging

function Set-PasskeyProvisionerLogSink {
    <#
    .SYNOPSIS
        Registers a scriptblock that receives every log entry: & $Sink $Message $Level $FormattedLine.
        Call without parameters to restore the default (information stream).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Only sets an in-memory variable')]
    [CmdletBinding()]
    param([scriptblock]$Sink)
    $script:LogSink = $Sink
}

function Start-PasskeyProvisionerLogFile {
    <#
    .SYNOPSIS
        Starts writing every log entry to a new file <yyyyMMdd-HHmmss>.log and returns its path.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates a log file; not a user-facing state change')]
    [CmdletBinding()]
    param([string]$Directory = (Get-PasskeyProvisionerConfig).logDirectory)

    if (-not (Test-Path -LiteralPath $Directory)) {
        [void][System.IO.Directory]::CreateDirectory($Directory)
    }
    $path = Join-Path $Directory ('{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $n = 1
    while (Test-Path -LiteralPath $path) {
        $path = Join-Path $Directory ('{0}-{1}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $n)
        $n++
    }
    [System.IO.File]::WriteAllText($path, '', (New-Object System.Text.UTF8Encoding $false))
    $script:LogFile = $path
    return $path
}

function Stop-PasskeyProvisionerLogFile {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Only clears an in-memory variable')]
    [CmdletBinding()]
    param()
    $script:LogFile = $null
}

function Format-PasskeyProvisionerLogLine {
    <# '[HH:mm:ss] [>>]  message' - ASCII only. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Message,
        [Parameter(Position = 1)][ValidateSet('Info', 'Success', 'Warning', 'Error')][string]$Level = 'Info'
    )
    $prefix = switch ($Level) {
        'Success' { '[OK] ' }
        'Warning' { '[!!] ' }
        'Error'   { '[ERR]' }
        default   { '[>>] ' }
    }
    '[{0}] {1} {2}' -f (Get-Date -Format 'HH:mm:ss'), $prefix, $Message
}

function Write-PasskeyProvisionerLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Message,
        [Parameter(Position = 1)][ValidateSet('Info', 'Success', 'Warning', 'Error')][string]$Level = 'Info'
    )
    $line = Format-PasskeyProvisionerLogLine -Message $Message -Level $Level
    if ($script:LogSink) {
        & $script:LogSink $Message $Level $line
    } else {
        Write-Information -MessageData $line -InformationAction Continue
    }
    if ($script:LogFile) {
        # .NET call on purpose: a cmdlet such as Add-Content would honor -WhatIf inherited from the caller and skip the write.
        try {
            [System.IO.File]::AppendAllText($script:LogFile, $line + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding $false))
        } catch {
            Write-Verbose "Could not write to log file '$script:LogFile': $_"
        }
    }
}

function Invoke-PasskeyProvisionerProgress {
    param([scriptblock]$Callback, [string]$Message, [bool]$Busy = $true)
    if ($Callback) { & $Callback $Message $Busy }
}

#endregion

#region Module management

function Test-ModuleVersionConflict {
    # Returns the version of an already loaded module that differs from the required one, or $null.
    # .NET cannot replace a loaded assembly, so Import-Module would fail with
    # "Assembly with same name is already loaded" or hang.
    param([string]$Name, [string]$RequiredVersion)
    $loaded = Get-Module -Name $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($loaded -and $loaded.Version -ne [version]$RequiredVersion) {
        return $loaded.Version
    }
    return $null
}

function Install-PasskeyProvisionerRequiredModule {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$RequiredVersion,
        [scriptblock]$ProgressCallback
    )

    Invoke-PasskeyProvisionerProgress $ProgressCallback "Checking module: $Name $RequiredVersion ..."
    $targetVersion = [version]$RequiredVersion
    $exactMatch = Get-Module -ListAvailable -Name $Name -ErrorAction SilentlyContinue |
                  Where-Object { $_.Version -eq $targetVersion } |
                  Select-Object -First 1

    if ($exactMatch) {
        Write-PasskeyProvisionerLog "  Module '$Name' $RequiredVersion is already installed." 'Info'
    } else {
        Write-PasskeyProvisionerLog "  Module '$Name' $RequiredVersion not found - installing from PowerShell Gallery (scope: CurrentUser)..." 'Info'
        Write-PasskeyProvisionerLog '  This may take 30-90 s on first install (Microsoft Graph ~100 MB).' 'Warning'
        Invoke-PasskeyProvisionerProgress $ProgressCallback "Installing $Name $RequiredVersion (please wait) ..."
        try {
            if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
                Write-PasskeyProvisionerLog '  Installing NuGet package provider...' 'Info'
                Install-PackageProvider -Name NuGet -Force -Scope CurrentUser | Out-Null
            }
            Install-Module -Name $Name -RequiredVersion $RequiredVersion -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
            Write-PasskeyProvisionerLog "  Module '$Name' $RequiredVersion installed successfully." 'Success'
        } catch {
            Write-PasskeyProvisionerLog "  Failed to install module '$Name' $RequiredVersion : $_" 'Error'
            throw
        }
    }

    $otherVersions = Get-Module -ListAvailable -Name $Name -ErrorAction SilentlyContinue |
                     Where-Object { $_.Version -ne $targetVersion } |
                     Select-Object -ExpandProperty Version -Unique
    if ($otherVersions) {
        Write-PasskeyProvisionerLog "  Note: other version(s) of '$Name' are installed as well: $($otherVersions -join ', '). They do not block, but can be removed with Uninstall-Module." 'Warning'
    }
}

function Initialize-PasskeyProvisionerModules {
    <#
    .SYNOPSIS
        Installs (if missing) and imports the pinned module versions the configuration needs (activeModules).
    .DESCRIPTION
        Fails fast with a clear message when a different version of a required module is already loaded in this
        process. In that case the PowerShell process must be restarted.
    .PARAMETER ProgressCallback
        Scriptblock called as & $cb $Message $Busy for status updates.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Initializes the whole pinned module set')]
    [CmdletBinding()]
    param(
        [object]$Config = (Get-PasskeyProvisionerConfig),
        [scriptblock]$ProgressCallback
    )

    $pins = $Config.activeModules
    Write-PasskeyProvisionerLog '[1/2] Checking required PowerShell modules...' 'Info'
    foreach ($name in $pins.Keys) {
        Install-PasskeyProvisionerRequiredModule -Name $name -RequiredVersion $pins[$name] -ProgressCallback $ProgressCallback
    }
    Write-PasskeyProvisionerLog 'All required modules are available.' 'Success'

    Write-PasskeyProvisionerLog '[2/2] Importing modules...' 'Info'
    Invoke-PasskeyProvisionerProgress $ProgressCallback 'Importing modules...'
    foreach ($name in $pins.Keys) {
        $conflict = Test-ModuleVersionConflict -Name $name -RequiredVersion $pins[$name]
        if ($conflict) {
            throw "Version $conflict of module '$name' is already loaded in this PowerShell session (required: $($pins[$name])). Close this window, open a new PowerShell process and start again."
        }
    }
    foreach ($name in $pins.Keys) {
        Import-Module -Name $name -RequiredVersion $pins[$name] -ErrorAction Stop
    }
    Write-PasskeyProvisionerLog 'All modules imported successfully.' 'Success'
}

#endregion

#region Graph connection

function Connect-PasskeyProvisionerGraph {
    [CmdletBinding()]
    param([string]$TenantId = (Get-PasskeyProvisionerConfig).tenantId)
    if (-not $TenantId) { throw 'No tenant given. Enter the tenant (name.onmicrosoft.com or tenant ID) or set tenantId in settings.json.' }
    Write-PasskeyProvisionerLog "Opening browser for admin authentication (tenant: $TenantId)..." 'Info'
    Connect-MgGraph -Scopes $script:GraphScope -TenantId $TenantId -NoWelcome -ErrorAction Stop
    Write-PasskeyProvisionerLog 'Connected to Microsoft Graph successfully.' 'Success'
}

function Disconnect-PasskeyProvisionerGraph {
    [CmdletBinding()]
    param()
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    Write-PasskeyProvisionerLog 'Disconnected from Microsoft Graph.' 'Info'
}

#endregion

#region Pure helpers

function Get-PasskeyProvisionerDisplayName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SerialId,
        [string]$Prefix = (Get-PasskeyProvisionerConfig).displayNamePrefix
    )
    '{0} {1}' -f $Prefix, $SerialId
}

function Get-PasskeyProvisionerDisplayNameCandidate {
    <# All display names under which a key with this serial may be registered: the current prefix first, then the legacy prefixes. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SerialId,
        [object]$Config = (Get-PasskeyProvisionerConfig)
    )
    $prefixes = @($Config.displayNamePrefix) + @($Config.legacyDisplayNamePrefixes) | Where-Object { $_ } | Select-Object -Unique
    foreach ($prefix in $prefixes) { '{0} {1}' -f $prefix, $SerialId }
}

function ConvertTo-Base64Url {
    <# WebAuthn style Base64Url: URL-safe alphabet, no padding. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][byte[]]$Bytes)
    [System.Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-PasskeyProvisionerGraphBody {
    <#
    .SYNOPSIS
        Builds the JSON request body for POST /users/{id}/authentication/fido2Methods.
    .DESCRIPTION
        The body is assembled as a string on purpose. ConvertTo-Json on nested hashtables serialized the nested
        objects incorrectly in the past (see CHANGELOG, 2026-08-18).
        $Passkey.Id is a byte[]; $Passkey.Response is a JSON string with clientDataJSON and attestationObject.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Pure function that only builds a string')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Passkey,
        [Parameter(Mandatory)][string]$DisplayName
    )

    $respObj = $Passkey.Response | ConvertFrom-Json
    $idB64Url = ConvertTo-Base64Url -Bytes $Passkey.Id

    # The display name comes from user input and is therefore escaped as a JSON string. clientDataJSON and
    # attestationObject are plain Base64Url strings and never contain characters that need escaping.
    $displayNameEscaped = ($DisplayName | ConvertTo-Json)

    @"
{
  "displayName": $displayNameEscaped,
  "publicKeyCredential": {
    "id": "$idB64Url",
    "response": {
      "clientDataJSON": "$($respObj.clientDataJSON)",
      "attestationObject": "$($respObj.attestationObject)"
    }
  }
}
"@
}

function Get-PasskeyProvisionerGraphErrorBody {
    # Extracts the Graph error body from an ErrorRecord. Handles both the HttpClient based and the legacy
    # HttpWebRequest based exception shapes.
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)
    $body = $null
    $response = $null
    if ($ErrorRecord.Exception.PSObject.Properties['Response']) { $response = $ErrorRecord.Exception.Response }
    if ($response -and $response.GetType().Name -eq 'HttpResponseMessage') {
        try { $body = $response.Content.ReadAsStringAsync().Result } catch { Write-Verbose "Could not read HttpResponseMessage body: $_" }
    } elseif ($response) {
        try {
            $reader = New-Object System.IO.StreamReader($response.GetResponseStream())
            $body = $reader.ReadToEnd()
        } catch { Write-Verbose "Could not read response stream: $_" }
    }
    if (-not $body -and $ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        $body = $ErrorRecord.ErrorDetails.Message
    }
    return $body
}

function Get-PasskeyProvisionerErrorHint {
    <#
    .SYNOPSIS
        Returns a human readable hint for well-known Graph failures, or $null.
    #>
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text)
    if ($Text -match '\b403\b|accessDenied|Forbidden|Authorization failed') {
        return 'Graph denied access (HTTP 403). Check that the Authentication Administrator role is active (activate it in PIM first). For users who hold admin roles themselves, the Privileged Authentication Administrator role is required.'
    }
    if ($Text -match '\b401\b|Unauthorized|InvalidAuthenticationToken') {
        return 'Graph rejected the sign-in token (HTTP 401). Disconnect, reconnect and sign in again.'
    }
    return $null
}

function Write-PasskeyProvisionerGraphHint {
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord, [string]$Body)
    $hint = Get-PasskeyProvisionerErrorHint -Text ("{0} {1}" -f $ErrorRecord.Exception.Message, $Body)
    if ($hint) { Write-PasskeyProvisionerLog "Hint: $hint" 'Warning' }
}

function Import-PasskeyProvisionerCsv {
    <#
    .SYNOPSIS
        Reads a bulk CSV with the columns UPN and SerialID. Values are trimmed.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $data = @(Import-Csv -LiteralPath $Path -ErrorAction Stop)
    if ($data.Count -eq 0) { throw 'The CSV file is empty.' }
    $names = $data[0].PSObject.Properties.Name
    if (($names -notcontains 'UPN') -or ($names -notcontains 'SerialID')) {
        throw "CSV must contain 'UPN' and 'SerialID' columns."
    }
    foreach ($row in $data) {
        [pscustomobject]@{
            UPN      = ([string]$row.UPN).Trim()
            SerialID = ([string]$row.SerialID).Trim()
        }
    }
}

#endregion

#region Result file

function Get-PasskeyProvisionerResultPath {
    <# users.csv -> users.result.csv (same folder). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CsvPath)
    $full = [System.IO.Path]::GetFullPath($CsvPath)
    [System.IO.Path]::ChangeExtension($full, 'result.csv')
}

function New-PasskeyProvisionerResultRecord {
    <# Status values: Registered, AlreadyRegistered, WhatIf, Failed, Aborted. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Pure function that only builds an object')]
    [CmdletBinding()]
    param(
        [string]$Upn,
        [string]$SerialId,
        [Parameter(Mandatory)][string]$Status,
        [string]$GraphId,
        [string]$ErrorMessage
    )
    [pscustomobject]@{
        Upn       = $Upn
        SerialId  = $SerialId
        Status    = $Status
        GraphId   = $GraphId
        Timestamp = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
        Error     = $ErrorMessage
    }
}

function Export-PasskeyProvisionerResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Result,
        [Parameter(Mandatory)][string]$Path
    )
    $Result | Select-Object Upn, SerialId, Status, GraphId, Timestamp, Error |
        Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
}

function Import-PasskeyProvisionerResult {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    @(Import-Csv -LiteralPath $Path -Encoding UTF8)
}

function Test-PasskeyProvisionerResultDone {
    <# True when an earlier run already registered (or confirmed) this user and serial. Used by -Resume. #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][object[]]$Result = @(),
        [Parameter(Mandatory)][string]$Upn,
        [Parameter(Mandatory)][string]$SerialId
    )
    $hit = $Result | Where-Object {
        $_.Upn -eq $Upn -and $_.SerialId -eq $SerialId -and $_.Status -in 'Registered', 'AlreadyRegistered'
    } | Select-Object -First 1
    return [bool]$hit
}

#endregion

#region Entra / Graph operations

function Get-PasskeyProvisionerUserKey {
    <# Returns all FIDO2 methods registered for the user. Errors are terminating on purpose: a failed lookup must
       never be mistaken for "not registered". #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Upn,
        [object]$Config = (Get-PasskeyProvisionerConfig)
    )
    try {
        if ($Config.graphApiVersion -eq 'v1.0') {
            @(Get-MgUserAuthenticationFido2Method -UserId $Upn -ErrorAction Stop)
        } else {
            @(Get-MgBetaUserAuthenticationFido2Method -UserId $Upn -ErrorAction Stop)
        }
    } catch {
        Write-PasskeyProvisionerGraphHint -ErrorRecord $_
        throw
    }
}

function Get-PasskeyProvisionerRegisteredKey {
    <# Finds keys registered for this serial under the current or any legacy display name prefix. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Upn,
        [Parameter(Mandatory)][string]$SerialId,
        [object]$Config = (Get-PasskeyProvisionerConfig)
    )
    $names = @(Get-PasskeyProvisionerDisplayNameCandidate -SerialId $SerialId -Config $Config)
    Get-PasskeyProvisionerUserKey -Upn $Upn -Config $Config | Where-Object { $names -contains $_.DisplayName }
}

function New-PasskeyProvisionerPasskeyRegistration {
    # Creates the passkey on the key (touch required) and registers it in Entra via a manually built body.
    # Private: only called from Register-PasskeyProvisionerPasskey, which owns the ShouldProcess confirmation.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Called only from Register-PasskeyProvisionerPasskey, which supports ShouldProcess')]
    param(
        [Parameter(Mandatory)][string]$Upn,
        [Parameter(Mandatory)][string]$DisplayName,
        [ValidateSet('beta', 'v1.0')][string]$ApiVersion = 'beta'
    )
    try {
        $options = Get-PasskeyRegistrationOptions -UserId $Upn -ErrorAction Stop
        # No -DisplayName: New-Passkey 3.2.0 does not accept it.
        $passkey = $options | New-Passkey -ErrorAction Stop

        $body = New-PasskeyProvisionerGraphBody -Passkey $passkey -DisplayName $DisplayName
        $uri  = 'https://graph.microsoft.com/{0}/users/{1}/authentication/fido2Methods' -f $ApiVersion, [System.Uri]::EscapeDataString($Upn)

        $registered = Invoke-MgGraphRequest -Uri $uri -Method POST -Body $body -ContentType 'application/json' -ErrorAction Stop
        Write-PasskeyProvisionerLog "Graph response displayName: '$($registered.displayName)' | id: $($registered.id)" 'Info'
        return $registered
    } catch {
        $errorBody = Get-PasskeyProvisionerGraphErrorBody -ErrorRecord $_
        if ($errorBody) {
            Write-PasskeyProvisionerLog "Graph error body: $errorBody" 'Error'
        } else {
            Write-PasskeyProvisionerLog "Graph error (no response body available): $($_.Exception.Message)" 'Error'
        }
        Write-PasskeyProvisionerGraphHint -ErrorRecord $_ -Body $errorBody
        throw
    }
}

function Test-PasskeyProvisionerRegistration {
    <#
    .SYNOPSIS
        Verifies that a key with the given display name exists. Retries because Graph does not always replicate a
        freshly created fido2Method to the GET endpoint immediately.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Upn,
        [Parameter(Mandatory)][string]$DisplayName,
        [int]$RetryCount = 3,
        [int]$RetryDelaySeconds = 2,
        [object]$Config = (Get-PasskeyProvisionerConfig)
    )
    $allKeys = @()
    $registeredKey = $null
    for ($i = 0; $i -lt $RetryCount; $i++) {
        $allKeys = @(Get-PasskeyProvisionerUserKey -Upn $Upn -Config $Config)
        $registeredKey = $allKeys | Where-Object { $_.DisplayName -eq $DisplayName } | Select-Object -First 1
        if ($registeredKey) { break }
        if ($i -lt ($RetryCount - 1)) { Start-Sleep -Seconds $RetryDelaySeconds }
    }
    if (-not $registeredKey) {
        $existing = ($allKeys | ForEach-Object { "'" + $_.DisplayName + "'" }) -join ', '
        Write-PasskeyProvisionerLog "Verify: display name '$DisplayName' not found. Existing fido2Methods for $Upn after retry: $existing" 'Warning'
        Write-PasskeyProvisionerLog "Failed to verify the registration of the passkey for $Upn." 'Error'
        throw "Verification failed for $Upn"
    }
    Write-PasskeyProvisionerLog "Passkey registered successfully for user $Upn." 'Success'
    return $registeredKey
}

function Register-PasskeyProvisionerPasskey {
    <#
    .SYNOPSIS
        Registers a FIDO2 key for a user unless a key with the same serial is already registered, under the current
        or a legacy display name prefix.
    .DESCRIPTION
        With -WhatIf the registration state is read from Graph, but the key is not touched and nothing is posted.
    .OUTPUTS
        Object with Upn, SerialId, DisplayName, Status (Registered, AlreadyRegistered, WhatIf) and GraphId.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Upn,
        [Parameter(Mandatory)][string]$SerialId,
        [object]$Config = (Get-PasskeyProvisionerConfig)
    )

    $displayName = Get-PasskeyProvisionerDisplayName -SerialId $SerialId -Prefix $Config.displayNamePrefix
    Write-PasskeyProvisionerLog "Checking existing registrations for $Upn..." 'Info'
    $existing = @(Get-PasskeyProvisionerRegisteredKey -Upn $Upn -SerialId $SerialId -Config $Config)

    $result = [pscustomobject]@{
        Upn = $Upn; SerialId = $SerialId; DisplayName = $displayName; Status = $null; GraphId = $null
    }

    if ($existing.Count -gt 0) {
        $foundName = $existing[0].DisplayName
        if ($foundName -ne $displayName) {
            Write-PasskeyProvisionerLog "Key is already registered under the legacy name '$foundName'." 'Warning'
        }
        Write-PasskeyProvisionerLog "Passkey already registered for user $Upn. Verifying..." 'Warning'
        $key = Test-PasskeyProvisionerRegistration -Upn $Upn -DisplayName $foundName -Config $Config
        $result.DisplayName = $foundName
        $result.Status      = 'AlreadyRegistered'
        $result.GraphId     = $key.Id
        return $result
    }

    if (-not $PSCmdlet.ShouldProcess($Upn, "Register passkey '$displayName'")) {
        $result.Status = 'WhatIf'
        return $result
    }

    Write-PasskeyProvisionerLog "Registering passkey '$displayName' for $Upn - please touch the key when prompted..." 'Info'
    $registered = New-PasskeyProvisionerPasskeyRegistration -Upn $Upn -DisplayName $displayName -ApiVersion $Config.graphApiVersion
    $key = Test-PasskeyProvisionerRegistration -Upn $Upn -DisplayName $displayName -Config $Config
    $result.Status  = 'Registered'
    $result.GraphId = if ($registered -and $registered.id) { $registered.id } else { $key.Id }
    return $result
}

#endregion

#region Input validation and summaries

function Test-PasskeyProvisionerSerial {
    <#
    .SYNOPSIS
        Validates a key serial. It must not be empty; when the configuration defines serialPattern it must match.
    .OUTPUTS
        Object with Valid (bool) and Message (empty when valid).
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$SerialId,
        [string]$Pattern = (Get-PasskeyProvisionerConfig).serialPattern
    )
    if ([string]::IsNullOrWhiteSpace($SerialId)) {
        return [pscustomobject]@{ Valid = $false; Message = 'Serial ID is required.' }
    }
    if ($Pattern -and ($SerialId.Trim() -notmatch $Pattern)) {
        return [pscustomobject]@{ Valid = $false; Message = "Serial ID does not match the expected format ($Pattern)." }
    }
    [pscustomobject]@{ Valid = $true; Message = '' }
}

function Test-PasskeyProvisionerUpn {
    <# Loose UPN check (name@domain.tld); Entra is the source of truth. #>
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Upn)
    if ([string]::IsNullOrWhiteSpace($Upn)) {
        return [pscustomobject]@{ Valid = $false; Message = 'UPN is required.' }
    }
    if ($Upn.Trim() -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
        return [pscustomobject]@{ Valid = $false; Message = 'Enter a valid UPN such as name@domain.com.' }
    }
    [pscustomobject]@{ Valid = $true; Message = '' }
}

function Get-PasskeyProvisionerResultSummary {
    <# Counts per outcome for the results page. #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Result = @())
    $count = { param($s) @($Result | Where-Object { $_.Status -eq $s }).Count }
    [pscustomobject]@{
        Total             = @($Result).Count
        Registered        = (& $count 'Registered')
        AlreadyRegistered = (& $count 'AlreadyRegistered')
        Failed            = (& $count 'Failed')
        Skipped           = (& $count 'Skipped')
    }
}

#endregion

#region Key swap gate

# Bulk enrollment needs a different physical key for every row. Windows reuses the same device instance path when a
# key is swapped in the same USB port, so "a key is present" cannot tell old from new. The gate therefore requires
# a real remove -> insert cycle after a key has been used.
#   WaitInsert : no key present yet
#   WaitRemove : the previous key is still plugged in
#   Ready      : a fresh key is present, enrollment may start

function New-PasskeyProvisionerKeyGate {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Pure function that only builds an object')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][bool]$KeyPresent)
    [pscustomobject]@{ State = $(if ($KeyPresent) { 'Ready' } else { 'WaitInsert' }) }
}

function Set-PasskeyProvisionerKeyGateUsed {
    <# Call after a key has been used for a registration. The next row needs a freshly inserted key. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Pure function that only builds an object')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][bool]$KeyPresent)
    [pscustomobject]@{ State = $(if ($KeyPresent) { 'WaitRemove' } else { 'WaitInsert' }) }
}

function Update-PasskeyProvisionerKeyGate {
    <# Advances the gate with the latest detection result. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Pure function that only builds an object')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Gate,
        [Parameter(Mandatory)][bool]$KeyPresent
    )
    $state = switch ($Gate.State) {
        'WaitRemove' { if ($KeyPresent) { 'WaitRemove' } else { 'WaitInsert' } }
        'WaitInsert' { if ($KeyPresent) { 'Ready' } else { 'WaitInsert' } }
        default      { if ($KeyPresent) { 'Ready' } else { 'WaitInsert' } }
    }
    [pscustomobject]@{ State = $state }
}

#endregion

#region Key management

function Remove-PasskeyProvisionerUserKey {
    <#
    .SYNOPSIS
        Deletes one FIDO2 registration of a user in Entra ID (for example after the key was factory reset).
    .DESCRIPTION
        Only the Entra registration is removed; the physical key is not touched. High impact: the user can no longer
        sign in with this key.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string]$Upn,
        [Parameter(Mandatory)][string]$KeyId,
        [string]$DisplayName,
        [object]$Config = (Get-PasskeyProvisionerConfig)
    )
    $label = $(if ($DisplayName) { "'$DisplayName' ($KeyId)" } else { $KeyId })
    if (-not $PSCmdlet.ShouldProcess($Upn, "Delete passkey registration $label")) { return }
    try {
        if ($Config.graphApiVersion -eq 'v1.0') {
            Remove-MgUserAuthenticationFido2Method -UserId $Upn -Fido2AuthenticationMethodId $KeyId -ErrorAction Stop
        } else {
            Remove-MgBetaUserAuthenticationFido2Method -UserId $Upn -Fido2AuthenticationMethodId $KeyId -ErrorAction Stop
        }
        Write-PasskeyProvisionerLog "Deleted passkey registration $label for $Upn." 'Success'
    } catch {
        Write-PasskeyProvisionerGraphHint -ErrorRecord $_
        throw
    }
}

function Get-PasskeyProvisionerResetCountdown {
    <#
    .SYNOPSIS
        Time left in the window in which a security key accepts a factory reset (10 seconds after it was powered up).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][datetime]$InsertedAt,
        [datetime]$Now = (Get-Date),
        [int]$WindowSeconds = 10
    )
    # [double] casts on purpose: [math]::Max(0, 0.4) picks the Int32 overload in PowerShell and returns 0.
    $elapsed = [double]($Now - $InsertedAt).TotalSeconds
    $window = [double]$WindowSeconds
    [pscustomobject]@{
        RemainingSeconds = [math]::Round([math]::Max([double]0, $window - $elapsed), 1)
        Fraction         = [math]::Min([double]1, [math]::Max([double]0, $elapsed / $window))
        Expired          = ($elapsed -ge $window)
    }
}

#endregion

#region Physical key detection

function ConvertTo-FidoKeyDevice {
    param([string]$Id, [string]$Name)
    $vid = [regex]::Match($Id, 'VID_([0-9A-Fa-f]{4})')
    $pidMatch = [regex]::Match($Id, 'PID_([0-9A-Fa-f]{4})')
    [pscustomobject]@{
        Detected   = $true
        Name       = $Name
        VID        = if ($vid.Success) { $vid.Groups[1].Value } else { 'N/A' }
        PID        = if ($pidMatch.Success) { $pidMatch.Groups[1].Value } else { 'N/A' }
        InstanceId = $Id
    }
}

function Get-FidoKeyDevice {
    <# Detects a plugged-in FIDO2 key via PnP (HID, known vendor ids or name patterns). #>
    [CmdletBinding()]
    param()
    $result = [pscustomobject]@{ Detected = $false; Name = ''; VID = ''; PID = ''; InstanceId = '' }
    $vidPattern  = 'VID_1050|VID_096E|VID_24DC|VID_2581|VID_20A0|VID_1E0D|VID_0483|VID_04E6|VID_1A44'
    $namePattern = 'FIDO|Security Key|YubiKey|Nitrokey|T2F2|OneSpan|eToken|WebAuthn'
    try {
        $dev = Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop |
            Where-Object {
                $_.DeviceID -match 'HID' -and
                ($_.DeviceID -match $vidPattern -or $_.Name -match $namePattern) -and
                $_.Status -eq 'OK'
            } | Select-Object -First 1
        if ($dev) { $result = ConvertTo-FidoKeyDevice -Id $dev.DeviceID -Name $dev.Name }
    } catch {
        Write-Verbose "CIM query failed, falling back to Get-PnpDevice: $_"
        try {
            $dev = Get-PnpDevice -Class 'HIDClass' -Status 'OK' -ErrorAction SilentlyContinue |
                Where-Object { $_.FriendlyName -match $namePattern -or $_.InstanceId -match $vidPattern } |
                Select-Object -First 1
            if ($dev) { $result = ConvertTo-FidoKeyDevice -Id $dev.InstanceId -Name $dev.FriendlyName }
        } catch { Write-Verbose "Get-PnpDevice failed: $_" }
    }
    return $result
}

function Get-FidoHidDevice {
    <# Lists all plugged-in HID devices with VID/PID and name. Used to identify a key that is not detected. #>
    [CmdletBinding()]
    param()
    try {
        Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop |
            Where-Object { $_.DeviceID -like 'HID\*' -and $_.Status -eq 'OK' -and $_.DeviceID -match 'VID_[0-9A-Fa-f]{4}' } |
            ForEach-Object { ConvertTo-FidoKeyDevice -Id $_.DeviceID -Name $_.Name }
    } catch {
        Write-Verbose "CIM query failed: $_"
    }
}

#endregion

Export-ModuleMember -Function @(
    'Get-PasskeyProvisionerConfig', 'Set-PasskeyProvisionerLogSink', 'Start-PasskeyProvisionerLogFile', 'Stop-PasskeyProvisionerLogFile',
    'Write-PasskeyProvisionerLog', 'Initialize-PasskeyProvisionerModules',
    'Connect-PasskeyProvisionerGraph', 'Disconnect-PasskeyProvisionerGraph', 'Get-PasskeyProvisionerDisplayName',
    'Get-PasskeyProvisionerDisplayNameCandidate', 'Get-PasskeyProvisionerUserKey',
    'Get-PasskeyProvisionerRegisteredKey', 'ConvertTo-Base64Url', 'New-PasskeyProvisionerGraphBody', 'Get-PasskeyProvisionerErrorHint',
    'Test-PasskeyProvisionerRegistration', 'Register-PasskeyProvisionerPasskey', 'Import-PasskeyProvisionerCsv',
    'Get-PasskeyProvisionerResultPath', 'New-PasskeyProvisionerResultRecord', 'Export-PasskeyProvisionerResult', 'Import-PasskeyProvisionerResult',
    'Test-PasskeyProvisionerResultDone', 'Get-FidoKeyDevice', 'Get-FidoHidDevice', 'Format-PasskeyProvisionerLogLine',
    'Test-PasskeyProvisionerSerial', 'Test-PasskeyProvisionerUpn', 'Get-PasskeyProvisionerResultSummary',
    'New-PasskeyProvisionerKeyGate', 'Set-PasskeyProvisionerKeyGateUsed', 'Update-PasskeyProvisionerKeyGate',
    'Remove-PasskeyProvisionerUserKey', 'Get-PasskeyProvisionerResetCountdown'
)
