#Requires -Version 5.1
<#
.SYNOPSIS
    Headless runner: registers FIDO2 keys in Entra ID for one user or for a CSV list.
.DESCRIPTION
    Console front end for PasskeyProvisioner.Core. Used for live tests and bulk runs where the admin still has to touch
    each key. Run it in a fresh PowerShell process (module version conflicts otherwise).
    Every run writes a log file to the configured log directory. In CSV mode a result file <csv>.result.csv
    (users.csv -> users.result.csv) is written after each row. With -Resume, rows that an earlier run already
    registered are skipped.
    With -WhatIf the registration state is read from Graph, but no key is touched, nothing is posted and no result
    file is written.
.PARAMETER Upn
    User principal name (single mode).
.PARAMETER SerialId
    Serial of the key (single mode). Part of the display name in Entra.
.PARAMETER CsvPath
    CSV file with the columns UPN and SerialID (bulk mode).
.PARAMETER Resume
    Skip rows that the existing result file marks as Registered or AlreadyRegistered (bulk mode).
.PARAMETER TenantId
    Overrides the tenant from the configuration.
.PARAMETER ConfigPath
    Explicit settings.json. Defaults to config/settings.json when present, otherwise built-in defaults.
.EXAMPLE
    .\Invoke-PasskeyProvisioner.ps1 -Upn user@example.com -SerialId "TEST KEY" -WhatIf
.EXAMPLE
    .\Invoke-PasskeyProvisioner.ps1 -CsvPath .\samples\users.sample.csv -Resume
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Console front end with colored output')]
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Single')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Single')][string]$Upn,
    [Parameter(Mandatory, ParameterSetName = 'Single')][string]$SerialId,
    [Parameter(Mandatory, ParameterSetName = 'Csv')][string]$CsvPath,
    [Parameter(ParameterSetName = 'Csv')][switch]$Resume,
    [string]$TenantId,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'

# -WhatIf must only affect the registration. Left on, the preference leaks into Import-Module, Install-Module and
# Connect-MgGraph (they would print "What if" lines or skip work). Remember the request and reset the preference.
$dryRun = [bool]$WhatIfPreference
$WhatIfPreference = $false

Import-Module (Join-Path $PSScriptRoot 'PasskeyProvisioner.Core\PasskeyProvisioner.Core.psd1') -Force

Set-PasskeyProvisionerLogSink -Sink {
    param($Message, $Level, $Line)
    $null = $Message  # the sink contract passes the raw message too; only the formatted line is printed here
    $color = switch ($Level) { 'Success' { 'Green' } 'Warning' { 'Yellow' } 'Error' { 'Red' } default { 'Gray' } }
    Write-Host $Line -ForegroundColor $color
}

$config = if ($ConfigPath) { Get-PasskeyProvisionerConfig -Path $ConfigPath } else { Get-PasskeyProvisionerConfig }
if (-not $TenantId) { $TenantId = $config.tenantId }
if (-not $TenantId) { throw 'No tenant given. Use -TenantId or set tenantId in settings.json.' }

$logPath = Start-PasskeyProvisionerLogFile -Directory $config.logDirectory
Write-PasskeyProvisionerLog "Log file: $logPath" 'Info'

$resultPath = $null
$previous = @()
if ($PSCmdlet.ParameterSetName -eq 'Csv') {
    $rows = @(Import-PasskeyProvisionerCsv -Path $CsvPath)
    Write-PasskeyProvisionerLog "CSV loaded: $($rows.Count) user(s) from '$CsvPath'" 'Success'
    $resultPath = Get-PasskeyProvisionerResultPath -CsvPath $CsvPath
    if ($Resume) {
        $previous = @(Import-PasskeyProvisionerResult -Path $resultPath)
        Write-PasskeyProvisionerLog "Resume: $($previous.Count) earlier result(s) read from '$resultPath'" 'Info'
    }
} else {
    $rows = @([pscustomobject]@{ UPN = $Upn.Trim(); SerialID = $SerialId.Trim() })
}

# Latest record per user and serial, in CSV order. Rows skipped by -Resume keep their earlier record.
$records = New-Object System.Collections.Specialized.OrderedDictionary
function Save-Record {
    if ($resultPath -and -not $dryRun) {
        Export-PasskeyProvisionerResult -Result @($records.Values) -Path $resultPath
    }
}

try {
    Initialize-PasskeyProvisionerModules -Config $config
    Connect-PasskeyProvisionerGraph -TenantId $TenantId

    $total = $rows.Count
    $current = 0
    foreach ($row in $rows) {
        $current++
        $key = '{0}|{1}' -f $row.UPN, $row.SerialID
        Write-PasskeyProvisionerLog "[$current/$total] Processing $($row.UPN) | Serial: $($row.SerialID)..." 'Info'

        if (-not $row.UPN -or -not $row.SerialID) {
            Write-PasskeyProvisionerLog 'Row skipped: UPN and SerialID are both required.' 'Error'
            $records[$key] = New-PasskeyProvisionerResultRecord -Upn $row.UPN -SerialId $row.SerialID -Status 'Failed' -ErrorMessage 'Missing UPN or SerialID'
            Save-Record
            continue
        }
        if ($Resume -and (Test-PasskeyProvisionerResultDone -Result $previous -Upn $row.UPN -SerialId $row.SerialID)) {
            Write-PasskeyProvisionerLog 'Skipped: already done in an earlier run (-Resume).' 'Info'
            $records[$key] = @($previous | Where-Object { $_.Upn -eq $row.UPN -and $_.SerialId -eq $row.SerialID } | Select-Object -Last 1)[0]
            continue
        }
        try {
            $r = Register-PasskeyProvisionerPasskey -Upn $row.UPN -SerialId $row.SerialID -Config $config -WhatIf:$dryRun
            $records[$key] = New-PasskeyProvisionerResultRecord -Upn $r.Upn -SerialId $r.SerialId -Status $r.Status -GraphId $r.GraphId
        } catch {
            Write-PasskeyProvisionerLog "Error processing $($row.UPN): $_" 'Error'
            $records[$key] = New-PasskeyProvisionerResultRecord -Upn $row.UPN -SerialId $row.SerialID -Status 'Failed' -ErrorMessage ("$_" -replace '\s+', ' ')
        }
        Save-Record
    }
} catch {
    Write-PasskeyProvisionerLog "Run aborted: $_" 'Error'
    $records['<aborted>'] = New-PasskeyProvisionerResultRecord -Status 'Aborted' -ErrorMessage ("$_" -replace '\s+', ' ')
} finally {
    Disconnect-PasskeyProvisionerGraph
}

$results = @($records.Values)
$failed = @($results | Where-Object { $_.Status -in 'Failed', 'Aborted' })
Write-PasskeyProvisionerLog ('Summary: {0} row(s), {1} failed.' -f $results.Count, $failed.Count) $(if ($failed.Count) { 'Warning' } else { 'Success' })
if ($resultPath -and -not $dryRun) { Write-PasskeyProvisionerLog "Result file: $resultPath" 'Info' }
$results | Select-Object Upn, SerialId, Status, GraphId, Error | Format-Table -AutoSize | Out-String | Write-Host
Stop-PasskeyProvisionerLogFile
exit $(if ($failed.Count) { 1 } else { 0 })
