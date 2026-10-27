[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal UI helper functions, not cmdlets')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Internal UI helper functions, not cmdlets')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'WPF event handlers must accept sender and event arguments')]
param()

# Application logic of the Passkey Provisioner GUI. Dot-sourced by Start-PasskeyProvisionerApp.ps1.
# All state lives in script scope. Long operations go through Invoke-AppRunspace (see Worker.ps1).

#region State

$script:Window         = $null
$script:ui             = @{}
$script:Config         = $null
$script:Worker         = $null
$script:Detector       = $null
$script:LogQueue       = $null
$script:Connected      = $false
$script:Connecting     = $false
$script:Busy           = $false
$script:Enrolling      = $false
$script:CancelRequested = $false
$script:OverrideKey    = $false
$script:Step           = 1
$script:Mode           = 'Single'
$script:Rows           = New-Object System.Collections.ObjectModel.ObservableCollection[PasskeyProvisioner.EnrollRow]
$script:Records        = New-Object System.Collections.Specialized.OrderedDictionary
$script:CsvPath        = $null
$script:ResultPath     = $null
$script:CsvRows        = @()
$script:PreviousResults = @()
$script:KeyPresent     = $false
$script:KeyDevice      = $null
$script:KeyTask        = $null
$script:Gate           = $null
$script:LogEntries     = New-Object System.Collections.Generic.List[object]
$script:LogFilter      = 'All'
$script:LogFilePath    = $null
$script:CurrentView    = 'Register'
$script:Themes         = $null
$script:ThemeName      = 'Dark'
$script:ThemeMode      = 'System'
$script:ThemeTimer     = $null
$script:KeyDialog      = [IntPtr]::Zero
$script:KeyDialogOwner = [IntPtr]::Zero
$script:KeyDialogGoneAt = $null
$script:KeyDialogBefore = @()
$script:ManageKind      = $null
$script:ManageInsertedAt = $null
$script:ManagePrevPresent = $false
$script:ManageAbsentSince = $null
$script:ManageRemoved = $false
$script:ManageMinAbsentSeconds = 1.5
$script:ManageTimer     = $null
$script:CleanupKeys     = @()
$script:CleanupUpn      = $null
$script:AutoConfirm     = $false
# Note: state variables must not share a name with a parameter of Start-PasskeyProvisionerApp.ps1 (same script scope).
$script:SimulationMode  = $false
$script:SimulationScript = $null

#endregion

#region Small helpers

function Set-AppBrush {
    # Binds a brush property to a theme resource. Unlike assigning a brush object, the binding follows theme switches.
    param([Parameter(Mandatory)]$Target, [Parameter(Mandatory)][string]$Property, [Parameter(Mandatory)][string]$Key)
    $type = $Target.GetType()
    $dp = [System.ComponentModel.DependencyPropertyDescriptor]::FromName($Property, $type, $type).DependencyProperty
    # Text and icons use the readable variant of an accent (see ThemeMath.ps1); shapes and borders use the exact palette color.
    $suffix = $(if ($Property -eq 'Foreground' -and $Key -in 'Love', 'Gold', 'Rose', 'Pine', 'Foam', 'Iris') { 'TextBrush' } else { 'Brush' })
    $Target.SetResourceReference($dp, $Key + $suffix)
}

function Get-AppBrush {
    param([Parameter(Mandatory)][string]$Name)
    $script:Window.FindResource($Name + 'Brush')
}

function Set-AppStatus {
    param([string]$Text, [bool]$Busy = $false)
    $ui.txtStatus.Text = $Text
    $ui.busyStatus.Visibility = $(if ($Busy) { 'Visible' } else { 'Collapsed' })
}

function Set-FieldError {
    # Shows or clears the inline error under a field and marks the field itself.
    param([Parameter(Mandatory)][string]$Field, [Parameter(Mandatory)][string]$Label, [string]$Message)
    $ui[$Label].Text = $Message
    $ui[$Label].Visibility = $(if ($Message) { 'Visible' } else { 'Collapsed' })
    $ui[$Field].Tag = $(if ($Message) { 'Invalid' } else { $null })
}

function Get-FirstLine {
    param([string]$Text, [int]$Max = 400)
    $line = (($Text -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 1)
    if (-not $line) { return '' }
    $line = $line.Trim()
    if ($line.Length -gt $Max) { $line = $line.Substring(0, $Max - 3) + '...' }
    return $line
}

#endregion

#region Themes

function ConvertTo-WpfColor {
    param([Parameter(Mandatory)][string]$Hex, [byte]$Alpha = 255)
    $c = [System.Windows.Media.ColorConverter]::ConvertFromString($Hex)
    [System.Windows.Media.Color]::FromArgb($Alpha, $c.R, $c.G, $c.B)
}

function Get-BlendedColor {
    # Mixes From toward To by Amount (0..1).
    param([System.Windows.Media.Color]$From, [System.Windows.Media.Color]$To, [double]$Amount)
    $mix = { param($a, $b) [byte][math]::Round($a + (($b - $a) * $Amount)) }
    [System.Windows.Media.Color]::FromRgb((& $mix $From.R $To.R), (& $mix $From.G $To.G), (& $mix $From.B $To.B))
}

function Set-BrushColor {
    param([Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][System.Windows.Media.Color]$Color)
    # Brushes in styles are frozen by WPF, so the resource entry is replaced instead of mutated.
    $script:Window.Resources[$Key] = [System.Windows.Media.SolidColorBrush]::new($Color)
}

function Get-UiSettingsPath {
    if ($env:PASSKEYPROVISIONER_UISETTINGS) { return $env:PASSKEYPROVISIONER_UISETTINGS }
    Join-Path $env:LOCALAPPDATA 'PasskeyProvisioner\ui-settings.json'
}

function Read-UiSettings {
    $path = Get-UiSettingsPath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Save-UiSettings {
    # Merges into the existing file: the theme choice and the last tenant live side by side.
    param([ValidateSet('System', 'Light', 'Dark')][string]$Mode, [string]$Tenant)
    $path = Get-UiSettingsPath
    try {
        $values = [ordered]@{}
        $old = Read-UiSettings
        if ($old) { foreach ($p in $old.PSObject.Properties) { $values[$p.Name] = $p.Value } }
        if ($Mode) { $values['theme'] = $Mode }
        if ($PSBoundParameters.ContainsKey('Tenant')) { $values['tenant'] = $Tenant }
        [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $path))
        [System.IO.File]::WriteAllText($path, ($values | ConvertTo-Json), (New-Object System.Text.UTF8Encoding $false))
    } catch {
        Write-Verbose "Could not save the UI settings: $_"
    }
}
function Get-SystemThemeName {
    # The Windows app mode (Settings > Personalization > Colors > Choose your mode).
    try {
        $light = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop).AppsUseLightTheme
        if ($light -eq 1) { return 'Light' }
    } catch { $null = $_ }
    return 'Dark'
}

function Get-InitialThemeMode {
    # An explicit request wins. 'Default' means the saved choice and, without one, the system setting.
    param([string]$Requested = 'Default')
    if ($Requested -in 'System', 'Dark', 'Light') { return $Requested }
    $saved = Read-UiSettings
    if ($saved -and $saved.theme -in 'System', 'Dark', 'Light') { return [string]$saved.theme }
    return 'System'
}

function Set-TitleBarColor {
    # Windows 11 title bar in the colors of the active theme (ignored silently on older builds).
    $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $script:Window).Handle
    if ($hwnd -eq [IntPtr]::Zero) { return }
    $theme = $script:Themes[$script:ThemeName]
    $colorRef = { param($hex) $c = ConvertTo-WpfColor $hex; [int](($c.B * 65536) + ($c.G * 256) + $c.R) }   # COLORREF is BGR
    [PasskeyProvisioner.Dwm]::Set($hwnd, 20, [int][bool]$theme.IsDark)   # immersive dark mode
    [PasskeyProvisioner.Dwm]::Set($hwnd, 35, (& $colorRef $theme.base))  # caption
    [PasskeyProvisioner.Dwm]::Set($hwnd, 36, (& $colorRef $theme.text))  # caption text
    [PasskeyProvisioner.Dwm]::Set($hwnd, 34, (& $colorRef $theme.overlay)) # border
}

function Set-AppTheme {
    <# Applies Dark (Rose Pine) or Light (Rose Pine Dawn) by changing the colors of the shared brushes in place. #>
    param([Parameter(Mandatory)][ValidateSet('Dark', 'Light')][string]$Name)
    $theme = $script:Themes[$Name]
    $roles = [ordered]@{
        Base = 'base'; Surface = 'surface'; Overlay = 'overlay'; Muted = 'muted'; Subtle = 'subtle'; Text = 'text'
        Love = 'love'; Gold = 'gold'; Rose = 'rose'; Pine = 'pine'; Foam = 'foam'; Iris = 'iris'
        HighlightLow = 'highlightLow'; HighlightMed = 'highlightMed'; HighlightHigh = 'highlightHigh'
    }
    foreach ($key in $roles.Keys) { Set-BrushColor ($key + 'Brush') (ConvertTo-WpfColor $theme[$roles[$key]]) }

    $tintAlpha = $(if ($theme.IsDark) { 0x2E } else { 0x38 })
    foreach ($key in 'Love', 'Gold', 'Pine', 'Foam', 'Iris', 'Rose') {
        Set-BrushColor ($key + 'TintBrush') (ConvertTo-WpfColor $theme[$key.ToLower()] $tintAlpha)
    }

    # Readable variants: text on the base, the surface and on the accent's own tint (the badge background).
    $readable = Get-ThemeReadableColor -Theme $theme
    foreach ($key in $readable.Keys) { Set-BrushColor $key (ConvertTo-WpfColor $readable[$key]) }

    $iris = ConvertTo-WpfColor $readable.IrisButtonBrush
    $white = [System.Windows.Media.Colors]::White; $black = [System.Windows.Media.Colors]::Black
    if ($theme.IsDark) {
        Set-BrushColor 'IrisHoverBrush' (Get-BlendedColor $iris $white 0.18)
        Set-BrushColor 'IrisPressedBrush' (Get-BlendedColor $iris $black 0.12)
    } else {
        Set-BrushColor 'IrisHoverBrush' (Get-BlendedColor $iris $black 0.10)
        Set-BrushColor 'IrisPressedBrush' (Get-BlendedColor $iris $black 0.20)
    }
    Set-BrushColor 'LoveHoverBrush' (ConvertTo-WpfColor $theme.love $(if ($theme.IsDark) { 0x4D } else { 0x55 }))
    Set-BrushColor 'LovePressedBrush' (ConvertTo-WpfColor $theme.love $(if ($theme.IsDark) { 0x66 } else { 0x70 }))

    $script:ThemeName = $Name
    Set-TitleBarColor
}

function Update-ThemeButton {
    # The button shows the selected mode (System, Light or Dark); a click selects the next one.
    $glyph = switch ($script:ThemeMode) { 'System' { 0xE7F4 } 'Light' { 0xE706 } default { 0xE708 } }
    $next = switch ($script:ThemeMode) { 'System' { 'Light' } 'Light' { 'Dark' } default { 'System' } }
    $ui.txtThemeIcon.Text = [string][char][int]$glyph
    $ui.txtThemeName.Text = $script:ThemeMode
    $detail = $(if ($script:ThemeMode -eq 'System') { "System: follows Windows, currently $($script:ThemeName.ToLower())" } else { $script:Themes[$script:ThemeName].DisplayName })
    $ui.btnTheme.ToolTip = "$detail. Click for $next (Ctrl+T)"
}

function Set-ThemeMode {
    # System follows the Windows app mode (and changes with it), Light and Dark are fixed.
    param([Parameter(Mandatory)][ValidateSet('System', 'Light', 'Dark')][string]$Mode, [switch]$Persist)
    $script:ThemeMode = $Mode
    Set-AppTheme -Name $(if ($Mode -eq 'System') { Get-SystemThemeName } else { $Mode })
    Update-ThemeButton
    if ($Persist) { Save-UiSettings -Mode $Mode }
}

function Switch-AppTheme {
    $next = switch ($script:ThemeMode) { 'System' { 'Light' } 'Light' { 'Dark' } default { 'System' } }
    Set-ThemeMode -Mode $next -Persist
}

function Update-SystemTheme {
    # Follows a change of the Windows app mode while System is selected.
    param([string]$SystemName = (Get-SystemThemeName))
    if ($script:ThemeMode -ne 'System') { return }
    $name = $SystemName
    if ($name -ne $script:ThemeName) {
        Set-AppTheme -Name $name
        Update-ThemeButton
    }
}

#endregion

#region Logging

function Test-LogFilter {
    param([string]$Level)
    switch ($script:LogFilter) {
        'All'     { return $true }
        default   { return ($Level -eq $script:LogFilter) }
    }
}

function Update-LogView {
    $lines = foreach ($e in $script:LogEntries) { if (Test-LogFilter $e.Level) { $e.Line } }
    $ui.txtLog.Text = (@($lines) -join "`r`n")
    $ui.txtLog.ScrollToEnd()
}

function Add-AppLogEntry {
    # Sink for Write-PasskeyProvisionerLog in the window runspace. The Core module writes the log file itself.
    param([string]$Message, [string]$Level, [string]$Line)
    [void]$script:LogEntries.Add([pscustomobject]@{ Level = $Level; Line = $Line })
    if (Test-LogFilter $Level) {
        $ui.txtLog.AppendText($Line + "`r`n")
        $ui.txtLog.ScrollToEnd()
    }
    if ($script:Connecting -and $Level -eq 'Info' -and -not $script:QuietDetail) {
        Set-AppBrush $ui.txtConnectDetail 'Foreground' 'Subtle'
        $ui.txtConnectDetail.Text = $Message.Trim()
    }
}

function Write-UiLog {
    param([Parameter(Mandatory)][string]$Message, [string]$Level = 'Info')
    Write-PasskeyProvisionerLog -Message $Message -Level $Level
}

function Receive-WorkerLog {
    # Messages written by code in the worker runspace arrive through the queue.
    $item = $null
    while ($script:LogQueue.TryDequeue([ref]$item)) {
        Write-PasskeyProvisionerLog -Message $item.Message -Level $item.Level
    }
}

#endregion

#region Views, steps and control state

function Show-View {
    param([ValidateSet('Register', 'Keys', 'Log')][string]$Name)
    $script:CurrentView = $Name
    $ui.viewRegister.Visibility = $(if ($Name -eq 'Register') { 'Visible' } else { 'Collapsed' })
    $ui.viewKeys.Visibility     = $(if ($Name -eq 'Keys') { 'Visible' } else { 'Collapsed' })
    $ui.viewLog.Visibility      = $(if ($Name -eq 'Log') { 'Visible' } else { 'Collapsed' })
    switch ($Name) {
        'Register' { $ui.txtViewTitle.Text = 'Register keys'; $ui.txtViewSubtitle.Text = 'Register FIDO2 security keys in Microsoft Entra ID on behalf of users.' }
        'Keys'     { $ui.txtViewTitle.Text = 'Keys'; $ui.txtViewSubtitle.Text = 'Inspect the plugged-in key and the passkeys registered for a user.' }
        'Log'      { $ui.txtViewTitle.Text = 'Activity log'; $ui.txtViewSubtitle.Text = 'Everything the tool does is recorded here and in the log file.' }
    }
}

function Set-StepperVisual {
    $labels = 'Connect', 'Source', 'Enroll', 'Results'
    for ($i = 1; $i -le 4; $i++) {
        $dot = $ui["stepDot$i"]; $txt = $ui["stepDotText$i"]; $lab = $ui["stepLabel$i"]
        if ($i -lt $script:Step) {
            Set-AppBrush $dot 'Background' 'Foam'
            $txt.FontFamily = $script:Window.FindResource('IconFont'); $txt.Text = [string][char]0xE73E; $txt.FontSize = 13
            Set-AppBrush $txt 'Foreground' 'Base'
            Set-AppBrush $lab 'Foreground' 'Text'
        } elseif ($i -eq $script:Step) {
            Set-AppBrush $dot 'Background' 'Iris'
            $txt.FontFamily = $script:Window.FontFamily; $txt.Text = [string]$i; $txt.FontSize = 13
            Set-AppBrush $txt 'Foreground' 'Base'
            Set-AppBrush $lab 'Foreground' 'Text'
        } else {
            Set-AppBrush $dot 'Background' 'Overlay'
            $txt.FontFamily = $script:Window.FontFamily; $txt.Text = [string]$i; $txt.FontSize = 13
            Set-AppBrush $txt 'Foreground' 'Muted'
            Set-AppBrush $lab 'Foreground' 'Muted'
        }
        $lab.Text = $labels[$i - 1]
    }
    for ($i = 1; $i -le 3; $i++) {
        Set-AppBrush $ui["stepLine$i"] 'Background' $(if ($i -lt $script:Step) { 'Foam' } else { 'Overlay' })
    }
}

function Set-Step {
    param([ValidateRange(1, 4)][int]$Step)
    $script:Step = $Step
    $ui.stepCardConnect.Visibility = $(if ($Step -eq 1) { 'Visible' } else { 'Collapsed' })
    $ui.stepCardSource.Visibility  = $(if ($Step -eq 2) { 'Visible' } else { 'Collapsed' })
    $ui.stepCardEnroll.Visibility  = $(if ($Step -eq 3) { 'Visible' } else { 'Collapsed' })
    $ui.stepCardResults.Visibility = $(if ($Step -eq 4) { 'Visible' } else { 'Collapsed' })
    Set-StepperVisual
    Update-Controls
}

function Get-FailedRowCount { @($script:Rows | Where-Object { $_.Status -eq 'Failed' }).Count }
function Get-PendingRowCount { @($script:Rows | Where-Object { $_.Status -in 'Pending', 'Cancelled' }).Count }

function Update-Controls {
    $idle = -not $script:Busy
    $ui.btnConnect.IsEnabled = $idle
    $ui.btnConnect.Content = $(if ($script:Connected) { 'Disconnect' } else { 'Connect' })
    $ui.btnConnect.Style = $(if ($script:Connected) { $script:Window.FindResource('SecondaryButton') } else { $script:Window.FindResource('PrimaryButton') })
    $ui.txtTenant.IsEnabled = $idle -and -not $script:Connected

    $ui.btnBack.Visibility = $(if ($script:Step -eq 1) { 'Collapsed' } else { 'Visible' })
    $ui.btnBack.IsEnabled = $idle -and $script:Step -gt 1
    $ui.btnNext.Visibility = $(if ($script:Step -ge 3) { 'Collapsed' } else { 'Visible' })
    $ui.btnNext.Content = $(if ($script:Step -eq 2) { 'Review' } else { 'Next' })
    $ui.btnNext.IsEnabled = $idle -and (($script:Step -eq 1 -and $script:Connected) -or $script:Step -eq 2)

    $ui.rbSingle.IsEnabled = $idle; $ui.rbCsv.IsEnabled = $idle
    $ui.txtUpn.IsEnabled = $idle; $ui.txtSerial.IsEnabled = $idle
    $ui.btnBrowse.IsEnabled = $idle; $ui.chkResume.IsEnabled = $idle

    $ui.btnStart.IsEnabled = $idle -and ((Get-PendingRowCount) -gt 0)
    $ui.btnRetry.IsEnabled = $idle -and ((Get-FailedRowCount) -gt 0)
    $ui.btnCancel.IsEnabled = $script:Enrolling -and -not $script:CancelRequested

    $ui.btnLookup.IsEnabled = $idle -and $script:Connected
    $ui.btnReset.IsEnabled = $idle; $ui.btnPin.IsEnabled = $idle
    $ui.btnCleanFind.IsEnabled = $idle -and $script:Connected
    $ui.btnCleanDelete.IsEnabled = $idle -and $script:Connected -and (@($script:CleanupKeys).Count -gt 0)
    $ui.btnExport.IsEnabled = $idle
    $ui.btnNewBatch.IsEnabled = $idle
}

function Set-Busy {
    param([bool]$Busy)
    $script:Busy = $Busy
    Update-Controls
}

function Set-ConnectionChip {
    param([string]$Account)
    if ($script:Connected) {
        Set-AppBrush $ui.dotConn 'Fill' 'Foam'
        $ui.txtConn.Text = $(if ($Account) { "Connected as $Account" } else { 'Connected' })
    } else {
        Set-AppBrush $ui.dotConn 'Fill' 'Gold'
        $ui.txtConn.Text = 'Not connected'
    }
}

#endregion

#region Connection

function Invoke-ConnectToggle {
    if ($script:Connected) { Invoke-Disconnect } else { Invoke-Connect }
}

function Invoke-Connect {
    $tenant = $ui.txtTenant.Text.Trim()
    if (-not $tenant -or $tenant -notmatch '^[A-Za-z0-9][A-Za-z0-9\.\-]*$') {
        Set-FieldError -Field 'txtTenant' -Label 'lblTenantError' -Message 'Enter the tenant as domain (name.onmicrosoft.com) or tenant ID.'
        return
    }
    Set-FieldError -Field 'txtTenant' -Label 'lblTenantError' -Message ''
    $ui.txtTenantChip.Text = $tenant

    Set-Busy $true
    $script:Connecting = $true
    $ui.busyConnect.Visibility = 'Visible'
    Set-AppBrush $ui.txtConnectDetail 'Foreground' 'Subtle'
    $ui.txtConnectDetail.Text = 'Starting...'
    Set-AppStatus 'Connecting to Microsoft Graph...' $true
    Write-UiLog "Connection process started (tenant: $tenant)." 'Info'
    try {
        Start-SignInWatch
        $info = Invoke-AppRunspace -Runspace $script:Worker -ArgumentList @($script:Config, $tenant, $script:SimulationMode) -OnTick { Update-SignInWindow } -Script {
            param($cfg, $tenantId, $simulate)
            if (-not $simulate) { Initialize-PasskeyProvisionerModules -Config $cfg }
            Connect-PasskeyProvisionerGraph -TenantId $tenantId
            $ctx = Get-MgContext
            [pscustomobject]@{ Account = [string]$ctx.Account; TenantId = [string]$ctx.TenantId }
        } | Select-Object -Last 1
        Receive-WorkerLog
        $script:Connected = $true
        Set-ConnectionChip -Account $info.Account
        Save-UiSettings -Tenant $tenant
        $ui.panelConnected.Visibility = 'Visible'
        $ui.txtConnectedAs.Text = "Connected as $($info.Account)  |  tenant $($info.TenantId)"
        $ui.txtConnectDetail.Text = ''
    } catch {
        Receive-WorkerLog
        $message = Get-FirstLine "$_"
        Write-UiLog "Module setup or connection failed: $message" 'Error'
        $hint = Get-PasskeyProvisionerErrorHint -Text "$_"
        if ($hint) { Write-UiLog "Hint: $hint" 'Warning' }
        Set-AppBrush $ui.txtConnectDetail 'Foreground' 'Love'
        $ui.txtConnectDetail.Text = $message
        $script:Connected = $false
        Set-ConnectionChip
    } finally {
        Stop-SignInWatch
        $script:Connecting = $false
        $ui.busyConnect.Visibility = 'Collapsed'
        Set-AppStatus 'Ready' $false
        Set-Busy $false
    }
}

function Invoke-Disconnect {
    Set-Busy $true
    Set-AppStatus 'Disconnecting...' $true
    try {
        Invoke-AppRunspace -Runspace $script:Worker -Script { Disconnect-PasskeyProvisionerGraph } | Out-Null
        Receive-WorkerLog
    } catch {
        Write-UiLog "Disconnect warning: $(Get-FirstLine "$_")" 'Warning'
    }
    $script:Connected = $false
    Set-ConnectionChip
    $ui.panelConnected.Visibility = 'Collapsed'
    Set-AppStatus 'Ready' $false
    Set-Busy $false
    Set-Step 1
}

#endregion

#region Source step

function Set-SourceMode {
    param([ValidateSet('Single', 'Csv')][string]$Mode)
    $script:Mode = $Mode
    $ui.panelSingle.Visibility = $(if ($Mode -eq 'Single') { 'Visible' } else { 'Collapsed' })
    $ui.panelCsv.Visibility    = $(if ($Mode -eq 'Csv') { 'Visible' } else { 'Collapsed' })
}

function Test-SingleInput {
    param([switch]$ShowEmptyErrors)
    $upn = $ui.txtUpn.Text.Trim(); $serial = $ui.txtSerial.Text.Trim()
    $ok = $true

    $r = Test-PasskeyProvisionerUpn -Upn $upn
    if (-not $r.Valid -and ($upn -or $ShowEmptyErrors)) { Set-FieldError 'txtUpn' 'lblUpnError' $r.Message } else { Set-FieldError 'txtUpn' 'lblUpnError' '' }
    if (-not $r.Valid) { $ok = $false }

    $r = Test-PasskeyProvisionerSerial -SerialId $serial -Pattern $script:Config.serialPattern
    if (-not $r.Valid -and ($serial -or $ShowEmptyErrors)) { Set-FieldError 'txtSerial' 'lblSerialError' $r.Message } else { Set-FieldError 'txtSerial' 'lblSerialError' '' }
    if (-not $r.Valid) { $ok = $false }
    return $ok
}

function Import-CsvSource {
    param([Parameter(Mandatory)][string]$Path)
    $ui.lblCsvError.Visibility = 'Collapsed'; $ui.txtCsvPath.Tag = $null
    try {
        $rows = @(Import-PasskeyProvisionerCsv -Path $Path)
    } catch {
        $script:CsvRows = @()
        $ui.borderCsvSummary.Visibility = 'Collapsed'
        Set-FieldError 'txtCsvPath' 'lblCsvError' (Get-FirstLine "$_")
        Write-UiLog "CSV load failed: $(Get-FirstLine "$_")" 'Error'
        return
    }
    $script:CsvPath = $Path
    $script:ResultPath = Get-PasskeyProvisionerResultPath -CsvPath $Path
    $ui.txtCsvPath.Text = $Path

    $checked = foreach ($r in $rows) {
        $u = Test-PasskeyProvisionerUpn -Upn $r.UPN
        $s = Test-PasskeyProvisionerSerial -SerialId $r.SerialID -Pattern $script:Config.serialPattern
        $msg = @($u.Message, $s.Message) | Where-Object { $_ }
        [pscustomobject]@{ Upn = $r.UPN; SerialId = $r.SerialID; Valid = ($u.Valid -and $s.Valid); Message = ($msg -join ' ') }
    }
    $script:CsvRows = @($checked)

    $invalid = @($script:CsvRows | Where-Object { -not $_.Valid })
    $dupes = @($script:CsvRows | Where-Object { $_.SerialId } | Group-Object SerialId | Where-Object { $_.Count -gt 1 })
    $ui.txtCsvSummary.Text = '{0} row(s) loaded, {1} valid, {2} invalid' -f $script:CsvRows.Count, ($script:CsvRows.Count - $invalid.Count), $invalid.Count
    $issues = @()
    foreach ($i in ($invalid | Select-Object -First 4)) { $issues += ("{0}: {1}" -f $(if ($i.Upn) { $i.Upn } else { '(empty)' }), $i.Message) }
    if ($invalid.Count -gt 4) { $issues += "... and $($invalid.Count - 4) more invalid row(s)" }
    foreach ($d in $dupes) { $issues += "Serial '$($d.Name)' appears $($d.Count) times." }
    $ui.txtCsvIssues.Text = ($issues -join "`n")
    $ui.txtCsvIssues.Visibility = $(if ($issues) { 'Visible' } else { 'Collapsed' })
    $ui.borderCsvSummary.Visibility = 'Visible'
    $csvTone = $(if ($invalid.Count -or $dupes.Count) { 'Gold' } else { 'Foam' })
    Set-AppBrush $ui.borderCsvSummary 'Background' ($csvTone + 'Tint')
    Set-AppBrush $ui.borderCsvSummary 'BorderBrush' $csvTone
    Write-UiLog "CSV loaded: $($script:CsvRows.Count) row(s) from '$Path' ($($invalid.Count) invalid)." $(if ($invalid.Count) { 'Warning' } else { 'Success' })
}

function New-EnrollRowList {
    # Turns the source (single input or CSV) into the grid rows. Returns $false when nothing can be enrolled.
    $script:Rows.Clear()
    $script:Records.Clear()
    $script:PreviousResults = @()

    if ($script:Mode -eq 'Single') {
        if (-not (Test-SingleInput -ShowEmptyErrors)) { return $false }
        $items = @([pscustomobject]@{ Upn = $ui.txtUpn.Text.Trim(); SerialId = $ui.txtSerial.Text.Trim(); Valid = $true; Message = '' })
        $script:ResultPath = $null
    } else {
        if (-not $script:CsvRows -or $script:CsvRows.Count -eq 0) {
            Set-FieldError 'txtCsvPath' 'lblCsvError' 'Choose a CSV file first.'
            return $false
        }
        $items = $script:CsvRows
        if ($ui.chkResume.IsChecked -and $script:ResultPath) {
            $script:PreviousResults = @(Import-PasskeyProvisionerResult -Path $script:ResultPath)
            if ($script:PreviousResults.Count) { Write-UiLog "Resume: $($script:PreviousResults.Count) earlier result(s) read from '$($script:ResultPath)'." 'Info' }
        }
    }

    $n = 0
    foreach ($item in $items) {
        $n++
        $row = New-Object PasskeyProvisioner.EnrollRow
        $row.Index = $n; $row.Upn = $item.Upn; $row.SerialId = $item.SerialId
        $key = '{0}|{1}' -f $item.Upn, $item.SerialId
        if (-not $item.Valid) {
            $row.Status = 'Failed'; $row.Detail = "Invalid input: $($item.Message)"
            # Invalid rows belong in the result file as well, one record per CSV row.
            $script:Records[$key] = New-PasskeyProvisionerResultRecord -Upn $item.Upn -SerialId $item.SerialId -Status 'Failed' -ErrorMessage $row.Detail
        } elseif ($script:PreviousResults.Count -and (Test-PasskeyProvisionerResultDone -Result $script:PreviousResults -Upn $item.Upn -SerialId $item.SerialId)) {
            $prev = @($script:PreviousResults | Where-Object { $_.Upn -eq $item.Upn -and $_.SerialId -eq $item.SerialId } | Select-Object -Last 1)[0]
            $row.Status = 'Skipped'; $row.GraphId = [string]$prev.GraphId
            $row.Detail = "Already done in an earlier run ($($prev.Status), $($prev.Timestamp))."
            $script:Records[$key] = $prev
        }
        $script:Rows.Add($row)
    }
    $ui.dgRows.ItemsSource = $script:Rows
    Update-BatchProgress
    return $true
}

#endregion

#region Enrollment

function Update-BatchProgress {
    $total = $script:Rows.Count
    $terminal = @($script:Rows | Where-Object { $_.Status -in 'Registered', 'AlreadyRegistered', 'Failed', 'Skipped' }).Count
    $ok = @($script:Rows | Where-Object { $_.Status -in 'Registered', 'AlreadyRegistered' }).Count
    $failed = Get-FailedRowCount
    $ui.progBatch.Value = $(if ($total) { [math]::Round(100 * $terminal / $total) } else { 0 })
    $ui.txtBatchProgress.Text = if ($total -eq 0) { 'Nothing to do' } else { '{0} of {1} processed  |  {2} succeeded  |  {3} failed' -f $terminal, $total, $ok, $failed }
}

function Show-Banner {
    param([ValidateSet('Gold', 'Iris', 'Pine', 'Foam', 'Love')][string]$Color = 'Gold', [string]$Title, [string]$Text, [bool]$ShowOverride = $false)
    Set-AppBrush $ui.bannerKey 'Background' ($Color + 'Tint')
    Set-AppBrush $ui.bannerKey 'BorderBrush' $Color
    Set-AppBrush $ui.txtBannerIcon 'Foreground' $Color
    $ui.txtBannerTitle.Text = $Title
    $ui.txtBannerText.Text = $Text
    $ui.btnOverride.Visibility = $(if ($ShowOverride) { 'Visible' } else { 'Collapsed' })
    $ui.bannerKey.Visibility = 'Visible'
}

function Hide-Banner { $ui.bannerKey.Visibility = 'Collapsed' }

function Save-ResultFile {
    if ($script:Mode -eq 'Csv' -and $script:ResultPath) {
        try { Export-PasskeyProvisionerResult -Result @($script:Records.Values) -Path $script:ResultPath }
        catch { Write-UiLog "Could not write the result file: $(Get-FirstLine "$_")" 'Warning' }
    }
}

function Set-RowOutcome {
    param(
        [Parameter(Mandatory)][PasskeyProvisioner.EnrollRow]$Row,
        [Parameter(Mandatory)][string]$Status,
        [string]$GraphId,
        [string]$Detail
    )
    $Row.Status = $Status
    $Row.GraphId = $GraphId
    $Row.Detail = $Detail
    $key = '{0}|{1}' -f $Row.Upn, $Row.SerialId
    $errorText = $(if ($Status -eq 'Failed') { $Detail } else { $null })
    $script:Records[$key] = New-PasskeyProvisionerResultRecord -Upn $Row.Upn -SerialId $Row.SerialId -Status $Status -GraphId $GraphId -ErrorMessage $errorText
    Save-ResultFile
    Update-BatchProgress
}

function Wait-ForKey {
    # Blocks (with a live message loop) until the key gate is ready, the user overrides it, or the batch is cancelled.
    param([Parameter(Mandatory)][PasskeyProvisioner.EnrollRow]$Row)
    $script:OverrideKey = $false
    while ($true) {
        if ($script:CancelRequested) { return $false }
        if ($script:OverrideKey -or $script:Gate.State -eq 'Ready') { return $true }
        if ($script:Gate.State -eq 'WaitRemove') {
            Show-Banner -Color 'Gold' -Title 'Remove the previous key and insert the next one' -ShowOverride $true `
                -Text ("Next: key {0} for {1}. The tool continues as soon as it sees a freshly inserted key." -f $Row.SerialId, $Row.Upn)
        } else {
            Show-Banner -Color 'Gold' -Title 'Insert the key' -ShowOverride $true `
                -Text ("Key {0} for {1}. The tool continues as soon as it detects the key." -f $Row.SerialId, $Row.Upn)
        }
        Invoke-UiPump
        Start-Sleep -Milliseconds 80
    }
}

function Invoke-Enrollment {
    param([switch]$RetryFailed)
    $targets = if ($RetryFailed) { @($script:Rows | Where-Object { $_.Status -eq 'Failed' }) } else { @($script:Rows | Where-Object { $_.Status -in 'Pending', 'Cancelled' }) }
    if ($targets.Count -eq 0) { return }

    $script:CancelRequested = $false
    $script:Enrolling = $true
    Set-Busy $true
    Set-AppStatus 'Enrolling keys...' $true
    $script:Gate = New-PasskeyProvisionerKeyGate -KeyPresent $script:KeyPresent
    Write-UiLog "Enrollment started: $($targets.Count) user(s)." 'Info'

    try {
        foreach ($row in $targets) {
            if ($script:CancelRequested) { break }
            $row.Detail = ''
            $label = "{0} (serial {1})" -f $row.Upn, $row.SerialId
            Write-UiLog "[$($row.Index)/$($script:Rows.Count)] Processing $label..." 'Info'

            $u = Test-PasskeyProvisionerUpn -Upn $row.Upn
            $s = Test-PasskeyProvisionerSerial -SerialId $row.SerialId -Pattern $script:Config.serialPattern
            if (-not ($u.Valid -and $s.Valid)) {
                Set-RowOutcome -Row $row -Status 'Failed' -Detail ("Invalid input: " + (@($u.Message, $s.Message) | Where-Object { $_ }) -join ' ')
                continue
            }

            # 1. Is it registered already? Then no key is needed at all.
            $row.Status = 'Checking'
            Set-AppStatus "Checking existing registrations for $($row.Upn)..." $true
            try {
                $found = @(Invoke-AppRunspace -Runspace $script:Worker -ArgumentList @($row.Upn, $row.SerialId, $script:Config) -Script {
                        param($upn, $serial, $cfg)
                        Get-PasskeyProvisionerRegisteredKey -Upn $upn -SerialId $serial -Config $cfg
                    })
                Receive-WorkerLog
            } catch {
                Receive-WorkerLog
                $lookupHint = Get-PasskeyProvisionerErrorHint -Text "$_"
                Write-UiLog "Lookup failed for $($row.Upn): $(Get-FirstLine "$_")" 'Error'
                Set-RowOutcome -Row $row -Status 'Failed' -Detail $(if ($lookupHint) { $lookupHint } else { Get-FirstLine "$_" })
                continue
            }
            if ($found.Count -gt 0) {
                Write-UiLog "Passkey already registered for $($row.Upn) as '$($found[0].DisplayName)'." 'Warning'
                Set-RowOutcome -Row $row -Status 'AlreadyRegistered' -GraphId ([string]$found[0].Id) -Detail "Registered as '$($found[0].DisplayName)'."
                continue
            }

            # 2. Wait for the physical key.
            $row.Status = 'WaitingForKey'
            Set-AppStatus "Waiting for key $($row.SerialId)..." $true
            if (-not (Wait-ForKey -Row $row)) {
                $row.Status = 'Pending'
                break
            }

            # 3. Register. The Windows security key dialog appears now; the key has to be touched.
            $row.Status = 'Running'
            Show-Banner -Color 'Iris' -Title 'Touch the key' -ShowOverride $false `
                -Text ("Confirm the Windows security key prompt for {0} and touch the key when it blinks." -f $row.Upn)
            Set-AppStatus "Registering key for $($row.Upn) - touch the key when prompted..." $true
            try {
                $result = Invoke-AppRunspace -Runspace $script:Worker -ArgumentList @($row.Upn, $row.SerialId, $script:Config) -Script {
                    param($upn, $serial, $cfg)
                    Register-PasskeyProvisionerPasskey -Upn $upn -SerialId $serial -Config $cfg
                } | Select-Object -Last 1
                Receive-WorkerLog
                $status = [string]$result.Status
                $detail = $(if ($status -eq 'Registered') { "Registered as '$($result.DisplayName)'." } else { "Already registered as '$($result.DisplayName)'." })
                Set-RowOutcome -Row $row -Status $status -GraphId ([string]$result.GraphId) -Detail $detail
            } catch {
                Receive-WorkerLog
                $hint = Get-PasskeyProvisionerErrorHint -Text "$_"
                Write-UiLog "Error processing $($row.Upn): $(Get-FirstLine "$_")" 'Error'
                Set-RowOutcome -Row $row -Status 'Failed' -Detail $(if ($hint) { $hint } else { Get-FirstLine "$_" })
            }
            Hide-Banner
            # The next row needs a different key.
            $script:Gate = Set-PasskeyProvisionerKeyGateUsed -KeyPresent $script:KeyPresent
        }
    } finally {
        Hide-Banner
        $script:Enrolling = $false
        Set-AppStatus 'Ready' $false
        Set-Busy $false
    }

    if ($script:CancelRequested) {
        Write-UiLog 'Enrollment cancelled.' 'Warning'
        Update-BatchProgress
    } else {
        $summary = Get-PasskeyProvisionerResultSummary -Result @($script:Rows)
        Write-UiLog ("Enrollment finished: {0} registered, {1} already registered, {2} failed, {3} skipped." -f $summary.Registered, $summary.AlreadyRegistered, $summary.Failed, $summary.Skipped) $(if ($summary.Failed) { 'Warning' } else { 'Success' })
        Show-Results
    }
}

#endregion

#region Results

function Show-Results {
    $s = Get-PasskeyProvisionerResultSummary -Result @($script:Rows)
    $ui.txtCountRegistered.Text = [string]$s.Registered
    $ui.txtCountAlready.Text    = [string]$s.AlreadyRegistered
    $ui.txtCountFailed.Text     = [string]$s.Failed
    $ui.txtCountSkipped.Text    = [string]$s.Skipped
    $open = Get-PendingRowCount
    $ui.txtResultHeadline.Text = $(if ($s.Failed) { "$($s.Total) user(s) processed, $($s.Failed) failed. Go back to the previous step to retry the failed rows." }
        elseif ($open) { "$($s.Total) user(s), $open not processed (cancelled)." }
        else { "All $($s.Total) user(s) processed without errors." })
    $ui.txtResultPath.Text = $(if ($script:Mode -eq 'Csv' -and $script:ResultPath) { "Result file: $($script:ResultPath)" } else { 'Use "Export results" to save this run as a CSV file.' })
    Set-Step 4
}

function Get-ResultRecords {
    foreach ($row in $script:Rows) {
        $key = '{0}|{1}' -f $row.Upn, $row.SerialId
        if ($script:Records.Contains($key)) { $script:Records[$key] }
        else { New-PasskeyProvisionerResultRecord -Upn $row.Upn -SerialId $row.SerialId -Status $row.Status -GraphId $row.GraphId -ErrorMessage $(if ($row.Status -eq 'Failed') { $row.Detail } else { $null }) }
    }
}

function Invoke-ExportResults {
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Title = 'Export results'
    $dlg.Filter = 'CSV files (*.csv)|*.csv'
    $dlg.FileName = 'fido-enroll-results-{0}.csv' -f (Get-Date -Format 'yyyyMMdd-HHmmss')
    if ($dlg.ShowDialog($script:Window)) {
        try {
            Export-PasskeyProvisionerResult -Result @(Get-ResultRecords) -Path $dlg.FileName
            Write-UiLog "Results exported to '$($dlg.FileName)'." 'Success'
            Set-AppStatus "Exported to $($dlg.FileName)" $false
        } catch {
            Write-UiLog "Export failed: $(Get-FirstLine "$_")" 'Error'
        }
    }
}

function Reset-Batch {
    $script:Rows.Clear(); $script:Records.Clear(); $script:PreviousResults = @()
    $ui.txtUpn.Text = ''; $ui.txtSerial.Text = ''
    Set-FieldError 'txtUpn' 'lblUpnError' ''; Set-FieldError 'txtSerial' 'lblSerialError' ''
    Update-BatchProgress
    Set-Step 2
}

#endregion

#region Key detection

function Update-KeyDisplay {
    $dev = $script:KeyDevice
    if ($dev -and $dev.Detected) {
        Set-AppBrush $ui.dotKey 'Fill' 'Foam'
        $ui.txtKey.Text = 'Key detected'
        Set-AppBrush $ui.borderKeyStatus 'Background' 'FoamTint'; Set-AppBrush $ui.borderKeyStatus 'BorderBrush' 'Foam'
        Set-AppBrush $ui.txtKeyStatusIcon 'Foreground' 'Foam'
        $ui.txtKeyStatusTitle.Text = 'Key detected'
        $ui.txtKeyStatusDetail.Text = "$($dev.Name)  |  VID $($dev.VID)  PID $($dev.PID)"
    } else {
        Set-AppBrush $ui.dotKey 'Fill' 'Muted'
        $ui.txtKey.Text = 'No key'
        Set-AppBrush $ui.borderKeyStatus 'Background' 'Base'; Set-AppBrush $ui.borderKeyStatus 'BorderBrush' 'Overlay'
        Set-AppBrush $ui.txtKeyStatusIcon 'Foreground' 'Muted'
        $ui.txtKeyStatusTitle.Text = 'No key detected'
        $ui.txtKeyStatusDetail.Text = 'Insert a FIDO2 security key. If it is plugged in but not detected, use "Show all USB HID devices".'
    }
}

function Invoke-KeyPoll {
    # Collects a finished detection and starts the next one. Never blocks.
    if ($script:KeyTask) {
        $result = Receive-AppRunspaceTask -Task $script:KeyTask
        if ($null -eq $result) { return }
        $script:KeyTask = $null
        $dev = @($result) | Select-Object -Last 1
        if ($dev) {
            $script:KeyDevice = $dev
            $script:KeyPresent = [bool]$dev.Detected
            if ($script:Gate) { $script:Gate = Update-PasskeyProvisionerKeyGate -Gate $script:Gate -KeyPresent $script:KeyPresent }
            Update-KeyDisplay
        }
    }
    if (-not $script:KeyTask -and $script:Detector) {
        $script:KeyTask = Start-AppRunspaceTask -Runspace $script:Detector -Script { Get-FidoKeyDevice }
    }
}

function Invoke-ListHid {
    $ui.btnListHid.IsEnabled = $false
    try {
        $devices = @(Invoke-AppRunspace -Runspace $script:Detector -Script { Get-FidoHidDevice })
        $text = if ($devices.Count -eq 0) { 'No HID devices with a USB vendor id found.' }
        else { ($devices | Sort-Object VID, PID | ForEach-Object { 'VID {0}  PID {1}  {2}' -f $_.VID, $_.PID, $_.Name }) -join "`r`n" }
        $ui.txtHidList.Text = $text
        $ui.txtHidList.Visibility = 'Visible'
        Write-UiLog "HID device list shown ($($devices.Count) device(s))." 'Info'
    } catch {
        $ui.txtHidList.Text = "Could not list devices: $(Get-FirstLine "$_")"
        $ui.txtHidList.Visibility = 'Visible'
    } finally {
        $ui.btnListHid.IsEnabled = $true
    }
}

function Invoke-Lookup {
    $upn = $ui.txtLookupUpn.Text.Trim()
    $v = Test-PasskeyProvisionerUpn -Upn $upn
    if (-not $v.Valid) { Set-AppBrush $ui.lblLookupInfo 'Foreground' 'Love'; $ui.lblLookupInfo.Text = $v.Message; return }
    Set-Busy $true
    Set-AppStatus "Looking up passkeys for $upn..." $true
    Set-AppBrush $ui.lblLookupInfo 'Foreground' 'Subtle'; $ui.lblLookupInfo.Text = 'Looking up...'
    try {
        $keys = @(Invoke-AppRunspace -Runspace $script:Worker -ArgumentList @($upn, $script:Config) -Script {
                param($u, $cfg)
                Get-PasskeyProvisionerUserKey -Upn $u -Config $cfg | ForEach-Object {
                    [pscustomobject]@{
                        DisplayName = [string]$_.DisplayName
                        Created     = $(if ($_.CreatedDateTime) { ([datetime]$_.CreatedDateTime).ToString('yyyy-MM-dd HH:mm') } else { '' })
                        Model       = [string]$_.Model
                    }
                }
            })
        Receive-WorkerLog
        $ui.dgLookup.ItemsSource = $keys
        $ui.dgLookup.Visibility = $(if ($keys.Count) { 'Visible' } else { 'Collapsed' })
        $ui.lblLookupInfo.Text = $(if ($keys.Count) { "$($keys.Count) passkey(s) registered for $upn." } else { "No passkeys registered for $upn." })
        Write-UiLog "Lookup: $($keys.Count) passkey(s) for $upn." 'Info'
    } catch {
        Receive-WorkerLog
        $ui.dgLookup.Visibility = 'Collapsed'
        Set-AppBrush $ui.lblLookupInfo 'Foreground' 'Love'
        $hint = Get-PasskeyProvisionerErrorHint -Text "$_"
        $ui.lblLookupInfo.Text = $(if ($hint) { $hint } else { Get-FirstLine "$_" })
        Write-UiLog "Lookup failed: $(Get-FirstLine "$_")" 'Error'
    } finally {
        Set-AppStatus 'Ready' $false
        Set-Busy $false
    }
}

#endregion

#region Key management (reset and PIN through the Windows dialog, Entra cleanup)

# Windows offers reset and PIN management to standard users in Settings > Accounts > Sign-in options > Security key.
# CTAP management through libfido2 needs administrator rights since Windows 10 1903, so the tool guides this dialog
# instead of talking to the key itself. Windows does not report the outcome back.
$script:KeyManagementUri = 'ms-settings:signinoptions-launchsecuritykeyenrollment'

function Confirm-AppAction {
    param([Parameter(Mandatory)][string]$Message, [string]$Title = 'Passkey Provisioner')
    if ($script:AutoConfirm) { return $true }
    return ([System.Windows.MessageBox]::Show($script:Window, $Message, $Title, 'YesNo', 'Warning') -eq 'Yes')
}

function Update-ManageCountdown {
    # Reset window: Windows accepts a reset only in the first 10 seconds after the key was inserted.
    if ($script:ManageKind -ne 'Reset') { return }
    # Only a removal that lasts is a removal: while Windows talks to the key (opening the dialog, choosing Reset) the detection can
    # lose the key for a moment, and that must not start the countdown. A real pull and re-insert takes longer than this.
    $now = Get-Date
    if ($script:KeyPresent) {
        if ($script:ManageAbsentSince) {
            $gone = ($now - $script:ManageAbsentSince).TotalSeconds
            if ($script:ManageRemoved) { $script:ManageInsertedAt = $now; Write-UiLog ('Key detected again after {0:N1} s: reset countdown started.' -f $gone) 'Info' }
            else { Write-UiLog ('Key was not detected for {0:N1} s while the guide was open; too short for a removal, ignored.' -f $gone) 'Info' }
        }
        $script:ManageAbsentSince = $null
        $script:ManageRemoved = $false
    } else {
        if (-not $script:ManageAbsentSince) { $script:ManageAbsentSince = $now }
        if (-not $script:ManageRemoved -and ($now - $script:ManageAbsentSince).TotalSeconds -ge $script:ManageMinAbsentSeconds) {
            $script:ManageRemoved = $true
            $script:ManageInsertedAt = $null
            Write-UiLog 'Key removed.' 'Info'
        }
    }
    $script:ManagePrevPresent = $script:KeyPresent

    if (-not $script:ManageInsertedAt) {
        $ui.panelResetCountdown.Visibility = 'Collapsed'
        return
    }
    $c = Get-PasskeyProvisionerResetCountdown -InsertedAt $script:ManageInsertedAt
    $ui.panelResetCountdown.Visibility = 'Visible'
    $ui.progReset.Value = [math]::Round(100 * (1 - $c.Fraction))
    if ($c.Expired) {
        $ui.txtResetCountdown.Text = 'The 10 second window has passed. Remove the key and insert it again.'
        Set-AppBrush $ui.progReset 'Foreground' 'Love'
        Set-AppBrush $ui.txtResetCountdown 'Foreground' 'Love'
    } else {
        $ui.txtResetCountdown.Text = ('Key inserted - choose Reset and touch the key within about {0:N0} s' -f [math]::Ceiling($c.RemainingSeconds))
        Set-AppBrush $ui.progReset 'Foreground' 'Gold'
        Set-AppBrush $ui.txtResetCountdown 'Foreground' 'Gold'
    }
}

function Show-ManageGuide {
    param([Parameter(Mandatory)][ValidateSet('Reset', 'Pin')][string]$Kind)
    $script:ManageKind = $Kind
    $script:ManageInsertedAt = $null
    $script:ManagePrevPresent = $script:KeyPresent
    $script:ManageAbsentSince = $null
    $script:ManageRemoved = $false
    $ui.panelResetCountdown.Visibility = 'Collapsed'
    if ($Kind -eq 'Reset') {
        $ui.txtManageTitle.Text = 'Reset the key'
        $ui.txtManageWarning.Text = 'This erases the PIN, the fingerprints and ALL passkeys on the key. It cannot be undone.'
        $ui.txtManageWarning.Visibility = 'Visible'
        $ui.txtManageSteps.Text = (@(
                "1. Click 'Open key management'. The Windows dialog opens over this window.",
                '2. In the Windows dialog choose Manage, then Reset.',
                '3. Windows asks you to remove the key, insert it again and touch it. A key accepts a reset only in the first 10 seconds after it was inserted; the countdown below starts when the tool sees the key come back.',
                '4. Click Done. If the key was registered before, remove the old registration in Entra (card on the right).'
            ) -join "`n")
        Set-AppBrush $ui.panelManage 'Background' 'LoveTint'
        Set-AppBrush $ui.panelManage 'BorderBrush' 'Love'
    } else {
        $ui.txtManageTitle.Text = 'Set or change the PIN'
        $ui.txtManageWarning.Visibility = 'Collapsed'
        $ui.txtManageSteps.Text = (@(
                "1. Click 'Open key management'. The Windows dialog opens over this window.",
                '2. In the Windows dialog choose Manage, then Add (no PIN yet) or Change.',
                '3. Touch the key when Windows asks and enter the new PIN.',
                'A PIN cannot be removed on its own. Only a factory reset clears it.'
            ) -join "`n")
        Set-AppBrush $ui.panelManage 'Background' 'PineTint'
        Set-AppBrush $ui.panelManage 'BorderBrush' 'Pine'
    }
    $ui.panelManage.Visibility = 'Visible'
    if ($script:KeyTimer) { $script:KeyTimer.Interval = [TimeSpan]::FromMilliseconds(700) }   # react faster while the window is open
    if (-not $script:ManageTimer) {
        $script:ManageTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:ManageTimer.Interval = [TimeSpan]::FromMilliseconds(200)
        $script:ManageTimer.Add_Tick({ Update-ManageCountdown; Watch-KeyDialog })
    }
    $script:ManageTimer.Start()
    Write-UiLog "Key management guide opened ($Kind)." 'Info'
}

function Hide-ManageGuide {
    Close-KeyDialogHost -CloseDialog
    if ($script:ManageTimer) { $script:ManageTimer.Stop() }
    if ($script:KeyTimer) { $script:KeyTimer.Interval = [TimeSpan]::FromSeconds(2) }
    $ui.panelManage.Visibility = 'Collapsed'
    $ui.panelResetCountdown.Visibility = 'Collapsed'
    $script:ManageKind = $null
}

function Get-AppWindowHandle {
    (New-Object System.Windows.Interop.WindowInteropHelper $script:Window).Handle
}

function Move-WindowToScreenCenter {
    # Centers a window of another application on the monitor that shows this tool and brings it to the front.
    param([Parameter(Mandatory)][IntPtr]$Window)
    $ours = Get-AppWindowHandle
    $a = [PasskeyProvisioner.WindowTools]::WorkAreaOf($ours)
    $d = [PasskeyProvisioner.WindowTools]::RectOf($Window)
    $pos = Get-CenteredOrigin -OuterLeft $a[0] -OuterTop $a[1] -OuterWidth $a[2] -OuterHeight $a[3] `
        -InnerWidth $d[2] -InnerHeight $d[3] -AreaLeft $a[0] -AreaTop $a[1] -AreaWidth $a[2] -AreaHeight $a[3]
    [PasskeyProvisioner.WindowTools]::MoveTo($Window, $pos.X, $pos.Y)
    [PasskeyProvisioner.WindowTools]::BringToFront($Window)
}

function Set-KeyDialogPosition {
    param([Parameter(Mandatory)][IntPtr]$Dialog)
    Move-WindowToScreenCenter -Window $Dialog
}

# --- sign-in window -----------------------------------------------------------------------------------------------
# While Connect-MgGraph runs, new windows are watched. The Microsoft sign-in dialog is parented to the console window
# of this process or to this window, so a new window that is owned by one of them is the sign-in window and is centered
# on the screen, as is a window of the Microsoft sign-in broker. Every new window is logged with process, class and
# owner, so an unexpected window shows up in the log. Windows of other programs are left alone.

$script:SignInKnown = $null
$script:SignInLastScan = [datetime]::MinValue
$script:QuietDetail = $false

function Start-SignInWatch {
    $script:SignInKnown = New-Object 'System.Collections.Generic.HashSet[long]'
    foreach ($h in [PasskeyProvisioner.WindowTools]::VisibleTopLevel()) { [void]$script:SignInKnown.Add($h) }
    $script:SignInLastScan = [datetime]::MinValue
}

function Stop-SignInWatch { $script:SignInKnown = $null }

function Update-SignInWindow {
    if (-not $script:SignInKnown) { return }
    if (((Get-Date) - $script:SignInLastScan).TotalMilliseconds -lt 120) { return }
    $script:SignInLastScan = Get-Date
    $ours = Get-AppWindowHandle
    $console = [PasskeyProvisioner.WindowTools]::ConsoleWindow()
    foreach ($h in [PasskeyProvisioner.WindowTools]::VisibleTopLevel()) {
        if (-not $script:SignInKnown.Add($h)) { continue }
        $ptr = [IntPtr]$h
        $procId = [PasskeyProvisioner.WindowTools]::ProcessIdOf($ptr)
        if ($procId -eq $PID) { continue }
        $owner = [PasskeyProvisioner.WindowTools]::OwnerOf($ptr)
        $name = try { (Get-Process -Id $procId -ErrorAction Stop).ProcessName } catch { '?' }
        $rect = [PasskeyProvisioner.WindowTools]::RectOf($ptr)
        $script:QuietDetail = $true
        Write-UiLog ("Window opened during sign-in: process {0}, class {1}, title '{2}', {3}x{4}, owner {5}." -f $name, [PasskeyProvisioner.WindowTools]::ClassName($ptr), [PasskeyProvisioner.WindowTools]::TitleOf($ptr), $rect[2], $rect[3], $(if ($owner -eq [IntPtr]::Zero) { 'none' } elseif ($owner -eq $ours) { 'this window' } elseif ($owner -eq $console) { 'console' } else { 'other' })) 'Info'
        $ownedByUs = ($owner -ne [IntPtr]::Zero) -and ($owner -eq $ours -or ($console -ne [IntPtr]::Zero -and $owner -eq $console))
        $broker = $name -in 'Microsoft.AAD.BrokerPlugin', 'CredentialUIBroker', 'msedgewebview2'
        if ($script:Config.centerPopupWindows -and ($ownedByUs -or $broker) -and $rect[2] -ge 200 -and $rect[3] -ge 200) {
            Move-WindowToScreenCenter -Window $ptr
            Write-UiLog 'Centered this window on the screen.' 'Info'
        }
        $script:QuietDetail = $false
    }
}

function Find-NewKeyDialog {
    # The dialog is a new visible top-level frame window that has an owner (the large Settings window).
    param([long[]]$Before = @())
    foreach ($h in [PasskeyProvisioner.WindowTools]::VisibleTopLevel()) {
        if ($Before -contains $h) { continue }
        $ptr = [IntPtr]$h
        if ([PasskeyProvisioner.WindowTools]::ClassName($ptr) -eq 'ApplicationFrameWindow' -and [PasskeyProvisioner.WindowTools]::OwnerOf($ptr) -ne [IntPtr]::Zero) { return $ptr }
    }
    return [IntPtr]::Zero
}

function Find-NewSettingsFrame {
    # New top-level frames (not in the snapshot taken before the link was opened) that host the Windows Settings app. The check is
    # language independent: it looks at the process behind the window, never at its title.
    param([long[]]$Before = @())
    $own = Get-AppWindowHandle
    foreach ($h in [PasskeyProvisioner.WindowTools]::VisibleTopLevel()) {
        if ($Before -contains $h) { continue }
        $ptr = [IntPtr]$h
        if ($ptr -eq $own) { continue }
        if ([PasskeyProvisioner.WindowTools]::ClassName($ptr) -eq 'ApplicationFrameWindow' -and [PasskeyProvisioner.WindowTools]::HostsProcess($ptr, 'SystemSettings')) { $ptr }
    }
}

function Close-LeftoverSettingsWindow {
    # After a reset Windows can bring up a Settings window ("Sign-in options") of its own once the dialog is gone. It belongs to
    # the dialog we opened, so close it too, but only windows that appeared after the link was opened.
    param([long[]]$Before = @())
    $until = (Get-Date).AddMilliseconds(1200)
    while ((Get-Date) -lt $until) { Invoke-UiPump; Start-Sleep -Milliseconds 50 }
    for ($round = 1; $round -le 3; $round++) {
        $left = @(Find-NewSettingsFrame -Before $Before)
        if ($left.Count -eq 0) { return }
        foreach ($ptr in $left) {
            [PasskeyProvisioner.WindowTools]::MakeInvisible($ptr)
            Write-UiLog ("Closing a Windows Settings window that was left behind: '{0}', {1}x{2}." -f [PasskeyProvisioner.WindowTools]::TitleOf($ptr), [PasskeyProvisioner.WindowTools]::RectOf($ptr)[2], [PasskeyProvisioner.WindowTools]::RectOf($ptr)[3]) 'Info'
            [PasskeyProvisioner.WindowTools]::Close($ptr)
        }
        $until = (Get-Date).AddMilliseconds(700)
        while ((Get-Date) -lt $until) { Invoke-UiPump; Start-Sleep -Milliseconds 50 }
    }
    if (@(Find-NewSettingsFrame -Before $Before).Count -gt 0) { Write-UiLog 'A Windows Settings window could not be closed; close it by hand.' 'Warning' }
}

function Close-KeyDialogHost {
    # Closes the large Settings window that was hidden for the dialog and, on request, the dialog itself.
    param([switch]$CloseDialog)
    if ($CloseDialog -and [PasskeyProvisioner.WindowTools]::IsVisibleWindow($script:KeyDialog)) {
        [PasskeyProvisioner.WindowTools]::Close($script:KeyDialog)
        $until = (Get-Date).AddMilliseconds(600)
        while ((Get-Date) -lt $until) { Invoke-UiPump; Start-Sleep -Milliseconds 50 }
    }
    if ($script:KeyDialogOwner -ne [IntPtr]::Zero -and [PasskeyProvisioner.WindowTools]::IsVisibleWindow($script:KeyDialogOwner)) {
        [PasskeyProvisioner.WindowTools]::Close($script:KeyDialogOwner)
    }
    $hadDialog = ($script:KeyDialog -ne [IntPtr]::Zero)
    $before = $script:KeyDialogBefore
    $script:KeyDialog = [IntPtr]::Zero
    $script:KeyDialogOwner = [IntPtr]::Zero
    $script:KeyDialogGoneAt = $null
    $script:KeyDialogBefore = @()
    if ($hadDialog -and -not $script:SimulationMode) { Close-LeftoverSettingsWindow -Before $before }
    if ($hadDialog -and $script:Window) { [void]$script:Window.Activate() }
}

function Watch-KeyDialog {
    # Called every 200 ms while the guide is open. When the dialog was closed (by the user), the hidden Settings window
    # must not stay behind in the taskbar. A short grace period covers dialogs that are replaced by a follow-up dialog.
    if ($script:KeyDialog -eq [IntPtr]::Zero) { return }
    if ([PasskeyProvisioner.WindowTools]::IsVisibleWindow($script:KeyDialog)) { $script:KeyDialogGoneAt = $null; return }
    if (-not $script:KeyDialogGoneAt) { $script:KeyDialogGoneAt = Get-Date }
    # a follow-up dialog owned by the same hidden window?
    if ($script:KeyDialogOwner -ne [IntPtr]::Zero) {
        foreach ($h in [PasskeyProvisioner.WindowTools]::VisibleTopLevel()) {
            $ptr = [IntPtr]$h
            if ([PasskeyProvisioner.WindowTools]::OwnerOf($ptr) -eq $script:KeyDialogOwner) {
                $script:KeyDialog = $ptr
                $script:KeyDialogGoneAt = $null
                Set-KeyDialogPosition -Dialog $ptr
                return
            }
        }
    }
    if (((Get-Date) - $script:KeyDialogGoneAt).TotalSeconds -ge 3) {
        Write-UiLog 'The Windows dialog was closed.' 'Info'
        Close-KeyDialogHost
    }
}

function Open-KeySettings {
    if ($script:SimulationMode) {
        Write-UiLog "(Simulation) would open $($script:KeyManagementUri)." 'Info'
        return
    }
    if ([PasskeyProvisioner.WindowTools]::IsVisibleWindow($script:KeyDialog)) {
        Set-KeyDialogPosition -Dialog $script:KeyDialog
        return
    }
    $before = @([PasskeyProvisioner.WindowTools]::VisibleTopLevel())
    $script:KeyDialogBefore = $before
    try {
        Start-Process -FilePath $script:KeyManagementUri
    } catch {
        Write-UiLog "Could not open the Windows security key dialog: $(Get-FirstLine "$_")" 'Error'
        Set-AppStatus 'Open it by hand: Settings > Accounts > Sign-in options > Security key > Manage.' $false
        return
    }
    Write-UiLog "Windows security key dialog requested ($($script:ManageKind)). Windows does not report the result back to this tool." 'Info'

    $ui.btnOpenKeySettings.IsEnabled = $false
    Set-AppStatus 'Opening the Windows security key dialog...' $true
    try {
        # The large Settings window must NOT be touched before the dialog exists: moving it off screen early stops Windows
        # from building the dialog at all (tested). So wait for the dialog, with a short poll interval, and hide it then.
        $dialog = [IntPtr]::Zero
        $deadline = (Get-Date).AddSeconds(15)
        # The large Settings window shows up about 3 seconds before the dialog, maximized. Moving it is not allowed yet, but making
        # it fully transparent is (tested: the dialog is still built), so it is never seen. Any other new window that was made
        # transparent by mistake is restored as soon as the dialog shows which window is the right one.
        $transparent = New-Object System.Collections.Generic.List[long]
        while ($dialog -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline) {
            Invoke-UiPump
            Start-Sleep -Milliseconds 10
            $dialog = Find-NewKeyDialog -Before $before
            # Only the first new frame: the dialog itself starts as a frame without owner, and hiding it breaks it.
            if ($dialog -eq [IntPtr]::Zero -and $transparent.Count -eq 0) {
                $own = Get-AppWindowHandle
                foreach ($h in [PasskeyProvisioner.WindowTools]::VisibleTopLevel()) {
                    $ptr = [IntPtr]$h
                    if ($before -contains $h -or $transparent.Contains($h) -or $ptr -eq $own) { continue }
                    if ([PasskeyProvisioner.WindowTools]::ClassName($ptr) -eq 'ApplicationFrameWindow' -and [PasskeyProvisioner.WindowTools]::OwnerOf($ptr) -eq [IntPtr]::Zero) {
                        [PasskeyProvisioner.WindowTools]::MakeInvisible($ptr)
                        $transparent.Add($h)
                    }
                }
            }
        }
        if ($dialog -ne [IntPtr]::Zero) {
            $rightOwner = [PasskeyProvisioner.WindowTools]::OwnerOf($dialog).ToInt64()
            foreach ($h in $transparent) { if ($h -ne $rightOwner) { [PasskeyProvisioner.WindowTools]::MakeVisible([IntPtr]$h) } }
        } else {
            foreach ($h in $transparent) { [PasskeyProvisioner.WindowTools]::MakeVisible([IntPtr]$h) }
        }
        if ($dialog -eq [IntPtr]::Zero) {
            Write-UiLog 'The small Windows dialog was not found; use the Windows Settings window that opened.' 'Warning'
            return
        }
        $owner = [PasskeyProvisioner.WindowTools]::OwnerOf($dialog)
        $script:KeyDialog = $dialog
        $script:KeyDialogGoneAt = $null
        # A Settings window the user already had open before is not ours to hide or close.
        if ($before -notcontains $owner.ToInt64()) {
            [PasskeyProvisioner.WindowTools]::MoveOffScreen($owner)
            $script:KeyDialogOwner = $owner
        } else {
            $script:KeyDialogOwner = [IntPtr]::Zero
        }
        Set-KeyDialogPosition -Dialog $dialog
        # the dialog may still resize while it builds its content
        $until = (Get-Date).AddMilliseconds(500)
        while ((Get-Date) -lt $until) { Invoke-UiPump; Start-Sleep -Milliseconds 50 }
        if ([PasskeyProvisioner.WindowTools]::IsVisibleWindow($dialog)) { Set-KeyDialogPosition -Dialog $dialog }
    } finally {
        $ui.btnOpenKeySettings.IsEnabled = $true
        Set-AppStatus 'Ready' $false
    }
}

function Complete-ManageGuide {
    $kind = $script:ManageKind
    Hide-ManageGuide
    if ($kind -eq 'Reset') {
        Write-UiLog 'Reset started via Windows Settings. The result is not reported back; check by registering the key or with Detect.' 'Warning'
        Set-AppStatus 'Reset finished? Remove the old registration in Entra if the key was registered before.' $false
    } elseif ($kind -eq 'Pin') {
        Write-UiLog 'PIN change started via Windows Settings. The result is not reported back.' 'Info'
        Set-AppStatus 'Ready' $false
    }
}

function Invoke-CleanupFind {
    $upn = $ui.txtCleanUpn.Text.Trim(); $serial = $ui.txtCleanSerial.Text.Trim()
    $script:CleanupKeys = @(); $script:CleanupUpn = $null
    Set-AppBrush $ui.lblCleanInfo 'Foreground' 'Love'
    $u = Test-PasskeyProvisionerUpn -Upn $upn
    if (-not $u.Valid) { $ui.lblCleanInfo.Text = $u.Message; Update-Controls; return }
    $s = Test-PasskeyProvisionerSerial -SerialId $serial -Pattern $script:Config.serialPattern
    if (-not $s.Valid) { $ui.lblCleanInfo.Text = $s.Message; Update-Controls; return }
    if (-not $script:Connected) { $ui.lblCleanInfo.Text = 'Connect to Microsoft Graph first (Register, step 1).'; Update-Controls; return }

    Set-Busy $true
    Set-AppStatus "Looking for registrations of key $serial..." $true
    Set-AppBrush $ui.lblCleanInfo 'Foreground' 'Subtle'; $ui.lblCleanInfo.Text = 'Looking up...'
    try {
        $found = @(Invoke-AppRunspace -Runspace $script:Worker -ArgumentList @($upn, $serial, $script:Config) -Script {
                param($u, $sn, $cfg)
                Get-PasskeyProvisionerRegisteredKey -Upn $u -SerialId $sn -Config $cfg | ForEach-Object {
                    [pscustomobject]@{
                        Id          = [string]$_.Id
                        DisplayName = [string]$_.DisplayName
                        Created     = $(if ($_.CreatedDateTime) { ([datetime]$_.CreatedDateTime).ToString('yyyy-MM-dd HH:mm') } else { '' })
                    }
                }
            })
        Receive-WorkerLog
        if ($found.Count -eq 0) {
            $ui.lblCleanInfo.Text = "No registration for serial $serial found for $upn."
        } else {
            $script:CleanupKeys = $found; $script:CleanupUpn = $upn
            $names = ($found | ForEach-Object { "'$($_.DisplayName)' (created $($_.Created))" }) -join '; '
            Set-AppBrush $ui.lblCleanInfo 'Foreground' 'Text'
            $ui.lblCleanInfo.Text = "Found $($found.Count): $names"
        }
        Write-UiLog "Cleanup lookup: $($found.Count) registration(s) for $upn and serial $serial." 'Info'
    } catch {
        Receive-WorkerLog
        $hint = Get-PasskeyProvisionerErrorHint -Text "$_"
        Set-AppBrush $ui.lblCleanInfo 'Foreground' 'Love'
        $ui.lblCleanInfo.Text = $(if ($hint) { $hint } else { Get-FirstLine "$_" })
        Write-UiLog "Cleanup lookup failed: $(Get-FirstLine "$_")" 'Error'
    } finally {
        Set-AppStatus 'Ready' $false
        Set-Busy $false
    }
}

function Invoke-CleanupDelete {
    $keys = @($script:CleanupKeys); $upn = $script:CleanupUpn
    if ($keys.Count -eq 0 -or -not $upn) { return }
    $list = ($keys | ForEach-Object { "  - $($_.DisplayName)" }) -join "`n"
    if (-not (Confirm-AppAction -Message "Delete these registrations of $upn in Entra?`n`n$list`n`nThe user can no longer sign in with this key. The physical key is not changed.")) {
        Write-UiLog 'Deleting the registration was cancelled.' 'Info'
        return
    }
    Set-Busy $true
    Set-AppStatus "Deleting registration(s) for $upn..." $true
    $deleted = 0; $failed = 0
    foreach ($k in $keys) {
        try {
            Invoke-AppRunspace -Runspace $script:Worker -ArgumentList @($upn, $k.Id, $k.DisplayName, $script:Config) -Script {
                param($u, $id, $name, $cfg)
                Remove-PasskeyProvisionerUserKey -Upn $u -KeyId $id -DisplayName $name -Config $cfg -Confirm:$false
            } | Out-Null
            Receive-WorkerLog
            $deleted++
        } catch {
            Receive-WorkerLog
            $failed++
            Write-UiLog "Could not delete '$($k.DisplayName)': $(Get-FirstLine "$_")" 'Error'
        }
    }
    $script:CleanupKeys = @(); $script:CleanupUpn = $null
    if ($failed) {
        Set-AppBrush $ui.lblCleanInfo 'Foreground' 'Love'
        $ui.lblCleanInfo.Text = "$deleted deleted, $failed failed. See the log."
    } else {
        Set-AppBrush $ui.lblCleanInfo 'Foreground' 'Foam'
        $ui.lblCleanInfo.Text = "$deleted registration(s) deleted. The key can be registered again (Register)."
    }
    Set-AppStatus 'Ready' $false
    Set-Busy $false
}

#endregion

#region Window setup

function Get-NamedElementMap {
    param([Parameter(Mandatory)][string]$XamlText, [Parameter(Mandatory)][System.Windows.FrameworkElement]$Root)
    $map = @{}
    foreach ($m in [regex]::Matches($XamlText, 'x:Name="([A-Za-z0-9_]+)"')) {
        $name = $m.Groups[1].Value
        $el = $Root.FindName($name)
        if ($el) { $map[$name] = $el }
    }
    return $map
}

function Register-AppHandlers {
    $w = $script:Window

    # Navigation
    $ui.navRegister.Add_Checked({ Show-View 'Register' })
    $ui.navKeys.Add_Checked({ Show-View 'Keys' })
    $ui.navLog.Add_Checked({ Show-View 'Log'; $ui.txtLog.ScrollToEnd() })
    # Shortcuts and bongo cat share one compiled key hook (see Models.ps1): PowerShell runs only for Ctrl combinations.
    $script:KeyHooks = New-Object PasskeyProvisioner.KeyHooks($w, $ui.bongoArmL, $ui.bongoArmR, $ui.bongoDownL, $ui.bongoDownR)
    $script:KeyHooks.add_CtrlKeyDown({
            param($source, $e)
            switch ($e.Key) {
                'D1' { $ui.navRegister.IsChecked = $true; $e.Handled = $true }
                'D2' { $ui.navKeys.IsChecked = $true; $e.Handled = $true }
                'D3' { $ui.navLog.IsChecked = $true; $e.Handled = $true }
                'T'  { Switch-AppTheme; $e.Handled = $true }
            }
        })
    $ui.btnTheme.Add_Click({ Switch-AppTheme })

    # Bongo cat: one paw hits the desk per key press, left and right in turn (images: see assets/bongo/README.md).
    $script:CatImages = @{}
    foreach ($n in 'base', 'l-up', 'l-down', 'r-up', 'r-down') {
        $bi = New-Object System.Windows.Media.Imaging.BitmapImage
        $bi.BeginInit()
        $bi.UriSource = New-Object System.Uri (Join-Path $script:AppRoot "assets\bongo\bongo-$n.png")
        $bi.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bi.EndInit()
        $bi.Freeze()
        $script:CatImages[$n] = $bi
    }
    $ui.bongoBase.Source = $script:CatImages['base']
    $ui.bongoArmL.Source = $script:CatImages['l-up']
    $ui.bongoArmR.Source = $script:CatImages['r-up']
    $ui.bongoDownL.Source = $script:CatImages['l-down']
    $ui.bongoDownR.Source = $script:CatImages['r-down']
    # Raised arms stay behind the tenant chip; a paw that hits the desk is drawn in front of it (flat "down" image) and stays
    # down as long as its key is held (KeyHooks).

    # Step 1
    $ui.btnConnect.Add_Click({ Invoke-ConnectToggle })
    $ui.txtTenant.Add_TextChanged({ Set-FieldError 'txtTenant' 'lblTenantError' '' })
    $ui.txtTenant.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return' -and -not $script:Busy -and -not $script:Connected) { Invoke-Connect } })

    # Step 2
    $ui.rbSingle.Add_Checked({ Set-SourceMode 'Single' })
    $ui.rbCsv.Add_Checked({ Set-SourceMode 'Csv' })
    $ui.txtUpn.Add_TextChanged({ [void](Test-SingleInput) })
    $ui.txtSerial.Add_TextChanged({ [void](Test-SingleInput) })
    $ui.btnBrowse.Add_Click({
            $dlg = New-Object Microsoft.Win32.OpenFileDialog
            $dlg.Title = 'Select CSV file'
            $dlg.Filter = 'CSV files (*.csv)|*.csv|All files (*.*)|*.*'
            if ($dlg.ShowDialog($script:Window)) { Import-CsvSource -Path $dlg.FileName }
        })

    # Footer navigation
    $ui.btnBack.Add_Click({ if (-not $script:Busy -and $script:Step -gt 1) { Set-Step ($script:Step - 1) } })
    $ui.btnNext.Add_Click({
            if ($script:Busy) { return }
            if ($script:Step -eq 1 -and $script:Connected) { Set-Step 2 }
            elseif ($script:Step -eq 2) {
                if (New-EnrollRowList) {
                    Hide-Banner
                    Set-Step 3
                    $ui.btnStart.Focus() | Out-Null
                }
            }
        })

    # Step 3
    $ui.btnStart.Add_Click({ Invoke-Enrollment })
    $ui.btnRetry.Add_Click({ Invoke-Enrollment -RetryFailed })
    $ui.btnCancel.Add_Click({
            $script:CancelRequested = $true
            Write-UiLog 'Cancel requested - stopping after the current user.' 'Warning'
            Update-Controls
        })
    $ui.btnOverride.Add_Click({ $script:OverrideKey = $true; Write-UiLog 'Key swap check overridden by the user.' 'Warning' })

    # Step 4
    $ui.btnExport.Add_Click({ Invoke-ExportResults })
    $ui.btnOpenResults.Add_Click({
            $target = $(if ($script:ResultPath -and (Test-Path -LiteralPath $script:ResultPath)) { $script:ResultPath } else { $null })
            if ($target) { Start-Process -FilePath explorer.exe -ArgumentList "/select,`"$target`"" }
            elseif ($script:CsvPath) { Start-Process -FilePath explorer.exe -ArgumentList "`"$(Split-Path -Parent $script:CsvPath)`"" }
            else { Start-Process -FilePath explorer.exe -ArgumentList "`"$($script:Config.logDirectory)`"" }
        })
    $ui.btnNewBatch.Add_Click({ if (-not $script:Busy) { Reset-Batch } })

    # Keys view
    $ui.btnDetect.Add_Click({ Invoke-KeyPoll; Set-AppStatus 'Looking for a key...' $false })
    $ui.btnListHid.Add_Click({ Invoke-ListHid })
    $ui.btnLookup.Add_Click({ Invoke-Lookup })
    $ui.txtLookupUpn.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return' -and $ui.btnLookup.IsEnabled) { Invoke-Lookup } })

    # Manage key
    $ui.btnReset.Add_Click({ Show-ManageGuide -Kind 'Reset' })
    $ui.btnPin.Add_Click({ Show-ManageGuide -Kind 'Pin' })
    $ui.btnOpenKeySettings.Add_Click({ Open-KeySettings })
    $ui.btnManageDone.Add_Click({ Complete-ManageGuide })
    $ui.btnCleanFind.Add_Click({ Invoke-CleanupFind })
    $ui.btnCleanDelete.Add_Click({ Invoke-CleanupDelete })
    $ui.txtCleanSerial.Add_KeyDown({ param($source, $e) if ($e.Key -eq 'Return' -and $ui.btnCleanFind.IsEnabled) { Invoke-CleanupFind } })

    # Log view
    # The filter level travels in the Tag of each radio button (no closures: $script: does not resolve inside them).
    foreach ($pair in @(@('rbLogAll', 'All'), @('rbLogInfo', 'Info'), @('rbLogSuccess', 'Success'), @('rbLogWarning', 'Warning'), @('rbLogError', 'Error'))) {
        $ui[$pair[0]].Tag = $pair[1]
        $ui[$pair[0]].Add_Checked({ param($source, $e) $script:LogFilter = [string]$source.Tag; Update-LogView })
    }
    $ui.btnCopyLog.Add_Click({
            try { [System.Windows.Clipboard]::SetText($ui.txtLog.Text); Set-AppStatus 'Log copied to the clipboard.' $false }
            catch { Write-UiLog "Could not copy the log: $(Get-FirstLine "$_")" 'Warning' }
        })
    $ui.btnOpenLogFolder.Add_Click({
            if (-not (Test-Path -LiteralPath $script:Config.logDirectory)) { [void](New-Item -ItemType Directory -Path $script:Config.logDirectory -Force) }
            Start-Process -FilePath explorer.exe -ArgumentList "`"$($script:Config.logDirectory)`""
        })
    $ui.btnClearLog.Add_Click({ $ui.txtLog.Clear() })
}

function Stop-AppServices {
    try { Close-KeyDialogHost -CloseDialog } catch { $null = $_ }
    foreach ($t in 'LogTimer', 'KeyTimer', 'ManageTimer', 'ThemeTimer') {
        $timer = Get-Variable -Name $t -Scope Script -ValueOnly -ErrorAction SilentlyContinue
        if ($timer) { $timer.Stop() }
    }
    foreach ($rs in $script:Worker, $script:Detector) {
        if ($rs) { try { $rs.Close(); $rs.Dispose() } catch { $null = $_ } }
    }
}

function Initialize-AppServices {
    param([Parameter(Mandatory)][string]$CoreModulePath)
    Set-AppStatus 'Starting background services...' $true
    Invoke-UiPump
    $script:LogQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $script:Worker   = New-AppRunspace -CoreModulePath $CoreModulePath -LogQueue $script:LogQueue -SimulationScript $script:SimulationScript -ForwardLog
    $script:Detector = New-AppRunspace -CoreModulePath $CoreModulePath -LogQueue $script:LogQueue -SimulationScript $script:SimulationScript

    $script:LogTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:LogTimer.Interval = [TimeSpan]::FromMilliseconds(120)
    $script:LogTimer.Add_Tick({ Receive-WorkerLog })
    $script:LogTimer.Start()

    $script:KeyTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:KeyTimer.Interval = [TimeSpan]::FromSeconds(2)
    $script:KeyTimer.Add_Tick({ Invoke-KeyPoll })
    $script:KeyTimer.Start()
    Invoke-KeyPoll
    Set-AppStatus 'Ready' $false
}

#endregion

#region Demo data (screenshots and design review only)

function Initialize-DemoData {
    $script:Connected = $true
    $ui.txtTenant.Text = 'contoso.onmicrosoft.com'; $ui.txtTenantChip.Text = 'contoso.onmicrosoft.com'
    $ui.txtLogPath.Text = 'Log: C:\Users\admin\AppData\Local\PasskeyProvisioner\logs\20261026-135921.log'
    Set-ConnectionChip -Account 'admin@contoso.com'
    $ui.panelConnected.Visibility = 'Visible'
    $ui.txtConnectedAs.Text = 'Connected as admin@contoso.com  |  tenant 0f3c1e2a-demo'
    $script:KeyDevice = [pscustomobject]@{ Detected = $true; Name = 'FIDO U2F Security Key'; VID = '349E'; PID = '0014'; InstanceId = 'demo' }
    $script:KeyPresent = $true
    Update-KeyDisplay

    $demo = @(
        @('anna.meier@contoso.com', '0123456781', 'Registered', "Registered as 'FIDO SECURITY KEY 0123456781'."),
        @('ben.schulz@contoso.com', '0123456782', 'AlreadyRegistered', "Registered as 'T2F2-TypeC 0123456782'."),
        @('carla.nowak@contoso.com', '0123456783', 'Failed', 'Graph denied access (HTTP 403). Check that the Authentication Administrator role is active (activate it in PIM first).'),
        @('david.koch@contoso.com', '0123456784', 'Skipped', 'Already done in an earlier run (Registered, 2026-10-26T13:59:58).'),
        @('eva.lang@contoso.com', '0123456785', 'Running', ''),
        @('felix.braun@contoso.com', '0123456786', 'WaitingForKey', ''),
        @('greta.vogel@contoso.com', '0123456787', 'Pending', ''),
        @('hans.keller@contoso.com', '0123456788', 'Pending', '')
    )
    $script:Rows.Clear()
    $i = 0
    foreach ($d in $demo) {
        $i++
        $r = New-Object PasskeyProvisioner.EnrollRow
        $r.Index = $i; $r.Upn = $d[0]; $r.SerialId = $d[1]; $r.Status = $d[2]; $r.Detail = $d[3]
        $script:Rows.Add($r)
    }
    $ui.dgRows.ItemsSource = $script:Rows
    Update-BatchProgress
    $ui.txtUpn.Text = 'anna.meier@contoso.com'; $ui.txtSerial.Text = '0123456781'
    $ui.txtCsvPath.Text = 'C:\Users\admin\Documents\users.csv'
    $ui.txtCsvSummary.Text = '8 row(s) loaded, 7 valid, 1 invalid'
    $ui.txtCsvIssues.Text = "carla.nowak@contoso: Enter a valid UPN such as name@domain.com.`nSerial '0123456784' appears 2 times."
    $ui.borderCsvSummary.Visibility = 'Visible'
    Set-AppBrush $ui.borderCsvSummary 'Background' 'GoldTint'; Set-AppBrush $ui.borderCsvSummary 'BorderBrush' 'Gold'
    $ui.txtCountRegistered.Text = '5'; $ui.txtCountAlready.Text = '1'; $ui.txtCountFailed.Text = '1'; $ui.txtCountSkipped.Text = '1'
    $ui.txtResultHeadline.Text = '8 user(s) processed, 1 failed. Go back to the previous step to retry the failed rows.'
    $ui.txtResultPath.Text = 'Result file: C:\Users\admin\Documents\users.result.csv'
    $ui.lblLookupInfo.Text = '2 passkey(s) registered for anna.meier@contoso.com.'
    $ui.dgLookup.ItemsSource = @(
        [pscustomobject]@{ DisplayName = 'FIDO SECURITY KEY 0123456781'; Created = '2026-10-26 13:59'; Model = 'T2F2-TypeC' },
        [pscustomobject]@{ DisplayName = 'Microsoft Authenticator'; Created = '2026-03-02 09:12'; Model = '' }
    )
    $ui.dgLookup.Visibility = 'Visible'
    $ui.txtLookupUpn.Text = 'anna.meier@contoso.com'
    # Demo only: the real start-up lines (with the real user name and log path) must not show up in screenshots.
    $script:LogEntries.Clear(); $ui.txtLog.Clear()
    foreach ($e in @(
            @('Log file: C:\Users\admin\AppData\Local\PasskeyProvisioner\logs\20261026-135921.log', 'Info'),
            @('[1/2] Checking required PowerShell modules...', 'Info'),
            @('All modules imported successfully.', 'Success'),
            @('Connected to Microsoft Graph successfully.', 'Success'),
            @('Passkey already registered for ben.schulz@contoso.com as ''T2F2-TypeC 0123456782''.', 'Warning'),
            @('Error processing carla.nowak@contoso.com: Graph denied access (HTTP 403).', 'Error')
        )) { Write-PasskeyProvisionerLog -Message $e[0] -Level $e[1] }
}

function Save-WindowScreenshot {
    param([Parameter(Mandatory)][string]$Path)
    # Render the client content only (the title bar belongs to Windows and has a different size).
    $content = $script:Window.Content
    $script:Window.UpdateLayout()
    $width = [int]$content.ActualWidth; $height = [int]$content.ActualHeight
    $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($width, $height, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    # The content has no background of its own (the window paints it), so draw it onto the base color first.
    $bounds = New-Object System.Windows.Rect(0, 0, $width, $height)
    $visual = New-Object System.Windows.Media.DrawingVisual
    $dc = $visual.RenderOpen()
    $dc.DrawRectangle((Get-AppBrush 'Base'), $null, $bounds)
    # Fixed viewbox: without it the brush stretches to the visual's overflow bounds (for example an animated busy bar).
    $brush = New-Object System.Windows.Media.VisualBrush($content)
    $brush.ViewboxUnits = [System.Windows.Media.BrushMappingMode]::Absolute
    $brush.Viewbox = $bounds
    $brush.Stretch = [System.Windows.Media.Stretch]::None
    $brush.AlignmentX = [System.Windows.Media.AlignmentX]::Left
    $brush.AlignmentY = [System.Windows.Media.AlignmentY]::Top
    $dc.DrawRectangle($brush, $null, $bounds)
    $dc.Close()
    $rtb.Render($visual)
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $fs = [System.IO.File]::Create($Path)
    try { $enc.Save($fs) } finally { $fs.Close() }
}

#endregion

function Start-PasskeyProvisionerAppWindow {
    param(
        [Parameter(Mandatory)][string]$AppRoot,
        [Parameter(Mandatory)][string]$CoreModulePath,
        [string]$ConfigPath,
        [string]$InitialView = 'Register',
        [int]$InitialStep = 1,
        [switch]$Demo,
        [string]$ScreenshotPath,
        [int]$ScreenshotDelayMs = 900,
        [switch]$Simulate,
        [string]$AutoRunScript,
        [ValidateSet('Default', 'System', 'Dark', 'Light')][string]$Theme = 'Default',
        [ValidateSet('None', 'Reset', 'Pin')][string]$InitialGuide = 'None'
    )

    $script:SimulationMode = [bool]$Simulate
    if ($Simulate) { $script:SimulationScript = (Resolve-Path (Join-Path $AppRoot 'Simulation.ps1')).ProviderPath }
    $script:AutoRunScript = $AutoRunScript
    $script:Config = $(if ($ConfigPath) { Get-PasskeyProvisionerConfig -Path $ConfigPath } else { Get-PasskeyProvisionerConfig })

    $script:AppRoot = $AppRoot
    $themeText = [System.IO.File]::ReadAllText((Join-Path $AppRoot 'Theme.xaml'))
    $themeInner = [regex]::Match($themeText, '(?s)<ResourceDictionary[^>]*>(.*)</ResourceDictionary>\s*$').Groups[1].Value
    $xamlText = [System.IO.File]::ReadAllText((Join-Path $AppRoot 'MainWindow.xaml')).Replace('<!--THEME-->', $themeInner)
    try {
        $script:Window = [System.Windows.Markup.XamlReader]::Parse($xamlText)
    } catch {
        [System.Windows.MessageBox]::Show("The window could not be loaded:`n`n$($_.Exception.Message)", 'Passkey Provisioner', 'OK', 'Error') | Out-Null
        throw
    }
    $script:ui = Get-NamedElementMap -XamlText $xamlText -Root $script:Window
    $script:Themes = Import-PowerShellDataFile -Path (Join-Path $AppRoot 'Themes.psd1')
    Set-ThemeMode -Mode (Get-InitialThemeMode -Requested $Theme)
    # Follow the Windows app mode while System is selected.
    $script:ThemeTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:ThemeTimer.Interval = [TimeSpan]::FromSeconds(3)
    $script:ThemeTimer.Add_Tick({ Update-SystemTheme })
    $script:ThemeTimer.Start()

    $iconPath = Join-Path $AppRoot '..\..\assets\app.ico'
    if (Test-Path -LiteralPath $iconPath) {
        try { $script:Window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri](Resolve-Path -LiteralPath $iconPath).ProviderPath) } catch { $null = $_ }
    }

    # Initial values
    # Tenant: an explicit value in settings.json wins, otherwise the one used last time on this PC (nothing is built in).
    $startTenant = [string]$script:Config.tenantId
    if (-not $startTenant) { $saved = Read-UiSettings; if ($saved -and $saved.tenant) { $startTenant = [string]$saved.tenant } }
    $ui.txtTenant.Text = $startTenant
    $ui.txtTenantChip.Text = $(if ($startTenant) { $startTenant } else { 'No tenant yet' })
    $ui.txtApi.Text = 'Graph ' + $script:Config.graphApiVersion
    try { $ui.txtVersion.Text = 'v' + (Import-PowerShellDataFile -Path $CoreModulePath).ModuleVersion } catch { $null = $_ }
    $ui.dgRows.ItemsSource = $script:Rows

    # Logging: every entry goes to the log view and, through the Core module, to the log file.
    Set-PasskeyProvisionerLogSink -Sink { param($m, $l, $line) Add-AppLogEntry -Message $m -Level $l -Line $line }
    $script:LogFilePath = Start-PasskeyProvisionerLogFile -Directory $script:Config.logDirectory
    $ui.txtLogPath.Text = "Log: $($script:LogFilePath)"
    $ui.txtLogPath.ToolTip = $script:LogFilePath
    Write-UiLog "Passkey Provisioner started (Graph $($script:Config.graphApiVersion))." 'Info'
    Write-UiLog "Log file: $($script:LogFilePath)" 'Info'

    Register-AppHandlers
    Set-SourceMode 'Single'
    Set-ConnectionChip
    Update-KeyDisplay
    Set-Step 1
    Show-View 'Register'

    $script:Window.Add_SourceInitialized({ try { Set-TitleBarColor } catch { $null = $_ } })

    $script:Window.Add_ContentRendered({
            if ($script:ServicesStarted) { return }
            $script:ServicesStarted = $true
            if ($script:Demo) {
                # Design review mode: no background services, fake data.
                Initialize-DemoData
            } else {
                try { Initialize-AppServices -CoreModulePath $script:CoreModulePath }
                catch {
                    Write-UiLog "Background services could not be started: $(Get-FirstLine "$_")" 'Error'
                    Set-AppStatus 'Background services failed to start. See the log.' $false
                }
            }
            switch ($script:InitialView) { 'Keys' { $ui.navKeys.IsChecked = $true } 'Log' { $ui.navLog.IsChecked = $true } }
            if ($script:InitialStep -gt 1) { Set-Step $script:InitialStep }
            Update-Controls
            if ($script:InitialGuide -ne 'None') {
                Show-ManageGuide -Kind $script:InitialGuide
                # Design review: show the reset countdown as if the key had been inserted four seconds ago.
                if ($script:Demo -and $script:InitialGuide -eq 'Reset') { $script:ManageInsertedAt = (Get-Date).AddSeconds(-4); $script:ManagePrevPresent = $true; Update-ManageCountdown }
            }
            if ($script:SimulationMode) { Write-UiLog 'SIMULATION MODE: no real Graph calls, no real key.' 'Warning'; $ui.txtApi.Text = 'Simulation' }
            if ($script:AutoRunScript) {
                # Automated UI test: run on the window thread after the first layout pass.
                [void]$script:Window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::ApplicationIdle, [System.Action]{ . $script:AutoRunScript })
            }
            if ($script:ScreenshotPath) {
                $script:ShotTimer = New-Object System.Windows.Threading.DispatcherTimer
                $script:ShotTimer.Interval = [TimeSpan]::FromMilliseconds($script:ScreenshotDelayMs)
                $script:ShotTimer.Add_Tick({
                        $script:ShotTimer.Stop()
                        Save-WindowScreenshot -Path $script:ScreenshotPath
                        $script:Window.Close()
                    })
                $script:ShotTimer.Start()
            }
        })

    $script:Window.Add_Closing({
            param($source, $e)
            if ($script:Enrolling) {
                $answer = [System.Windows.MessageBox]::Show('An enrollment is running. Cancel it and close the window?', 'Passkey Provisioner', 'YesNo', 'Warning')
                if ($answer -ne 'Yes') { $e.Cancel = $true; return }
                $script:CancelRequested = $true
            }
            if ($script:Connected -and $script:Worker -and -not $script:Demo) {
                try { Invoke-AppRunspace -Runspace $script:Worker -Script { Disconnect-PasskeyProvisionerGraph } | Out-Null } catch { $null = $_ }
            }
            Stop-AppServices
            Stop-PasskeyProvisionerLogFile
        })

    $script:Demo = [bool]$Demo
    $script:CoreModulePath = $CoreModulePath
    $script:InitialGuide = $InitialGuide
    $script:InitialView = $InitialView
    $script:InitialStep = $InitialStep
    $script:ScreenshotPath = $ScreenshotPath
    $script:ScreenshotDelayMs = $ScreenshotDelayMs
    $script:ServicesStarted = $false

    [void]$script:Window.ShowDialog()
}
