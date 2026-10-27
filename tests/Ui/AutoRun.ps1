# Automated end-to-end test of the GUI in simulation mode. Runs INSIDE the app window (dot-sourced by the app) and
# therefore has access to its functions and controls. Start it with tests/Invoke-UiSimulationTest.ps1.
#
# Scenario (five CSV rows, one key plugged in at the start):
#   anna  -> new user, key present            -> Registered
#   ben   -> already registered (legacy name) -> AlreadyRegistered, needs no key
#   carla -> Graph answers 403                -> Failed with the PIM hint
#   (bad) -> invalid UPN                      -> Failed (invalid input), never sent to Graph
#   dave  -> new user, needs a swapped key    -> waits for remove + insert, then Registered
# Afterwards a second pass with "skip already registered" must skip anna, ben and dave.

$outFile   = $env:PASSKEYPROVISIONER_UITEST_OUT
$workDir   = $env:PASSKEYPROVISIONER_UITEST_DIR
$simKey    = Join-Path ([System.IO.Path]::GetTempPath()) 'passkeyprovisioner-sim-key.txt'
$checks    = New-Object System.Collections.Generic.List[object]
$banners   = New-Object System.Collections.Generic.List[string]

function Assert-Check {
    param([string]$Name, [bool]$Passed, [string]$Detail = '')
    $checks.Add([pscustomobject]@{ Name = $Name; Passed = $Passed; Detail = $Detail })
}

function Wait-Until {
    param([scriptblock]$Condition, [int]$TimeoutSeconds = 20)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while (-not (& $Condition)) {
        if ((Get-Date) -gt $deadline) { return $false }
        Invoke-UiPump
        Start-Sleep -Milliseconds 100
    }
    return $true
}

try {
    # Safety stop: this script must never run against the real Graph or open a real sign-in window.
    if (-not $script:SimulationMode -or -not $script:Worker) {
        Assert-Check 'simulation mode is active (refusing to run against a real tenant)' $false
        return
    }
    Set-Content -LiteralPath $simKey -Value '1'
    # Bongo cat: the paw goes down with the key and stays down while the key is held; the paws alternate
    $keySource = [System.Windows.PresentationSource]::FromVisual($script:Window)
    $sendKey = {
        param([System.Windows.Input.Key]$Key, [bool]$Down)
        $e = [System.Windows.Input.KeyEventArgs]::new([System.Windows.Input.Keyboard]::PrimaryDevice, $keySource, 0, $Key)
        $e.RoutedEvent = $(if ($Down) { [System.Windows.UIElement]::PreviewKeyDownEvent } else { [System.Windows.UIElement]::PreviewKeyUpEvent })
        $script:Window.RaiseEvent($e)
    }
    $paw = { param($side) $ui["bongoDown$side"].Visibility -eq 'Visible' -and $ui["bongoArm$side"].Visibility -eq 'Hidden' }
    $raised = { param($side) $ui["bongoDown$side"].Visibility -eq 'Hidden' -and $ui["bongoArm$side"].Visibility -eq 'Visible' }
    Assert-Check 'cat: both arms raised at rest' ((& $raised 'L') -and (& $raised 'R'))
    & $sendKey ([System.Windows.Input.Key]::A) $true
    Assert-Check 'cat: first key down = left paw down' ((& $paw 'L') -and (& $raised 'R'))
    Start-Sleep -Milliseconds 200
    Assert-Check 'cat: the paw stays down while the key is held' (& $paw 'L')
    & $sendKey ([System.Windows.Input.Key]::B) $true
    Assert-Check 'cat: second key down = right paw down as well' ((& $paw 'L') -and (& $paw 'R'))
    & $sendKey ([System.Windows.Input.Key]::A) $false
    Assert-Check 'cat: releasing the first key raises the left paw' ((& $raised 'L') -and (& $paw 'R'))
    Start-Sleep -Milliseconds 100
    & $sendKey ([System.Windows.Input.Key]::B) $false
    Assert-Check 'cat: releasing the second key raises the right paw' ((& $raised 'L') -and (& $raised 'R'))
    & $sendKey ([System.Windows.Input.Key]::C) $true
    & $sendKey ([System.Windows.Input.Key]::C) $false
    Assert-Check 'cat: a very quick tap stays visible for a moment' (& $paw 'L')
    if ($env:PASSKEYPROVISIONER_UITEST_DIR) { Save-WindowScreenshot -Path (Join-Path $env:PASSKEYPROVISIONER_UITEST_DIR 'cat-down.png') }
    Assert-Check 'cat: and then goes up' (Wait-Until { & $raised 'L' } 3)

    # ---- start-up state
    Assert-Check 'simulation banner in the top bar' ($ui.txtApi.Text -eq 'Simulation') $ui.txtApi.Text
    Assert-Check 'key detected at start' (Wait-Until { $script:KeyPresent } 20)
    Assert-Check 'Next is disabled before connecting' (-not $ui.btnNext.IsEnabled)

    # ---- theme modes: System follows Windows, Light = Rose Pine Dawn, Dark = Rose Pine
    $settingsFile = $env:PASSKEYPROVISIONER_UISETTINGS
    $savedMode = { (Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json).theme }
    Assert-Check 'starts in the dark mode' ($script:ThemeMode -eq 'Dark' -and $script:ThemeName -eq 'Dark' -and $ui.txtThemeName.Text -eq 'Dark') "$script:ThemeMode / $script:ThemeName / $($ui.txtThemeName.Text)"
    Assert-Check 'dark base is Rose Pine #191724' ($script:Window.FindResource('BaseBrush').Color.ToString() -eq '#FF191724') $script:Window.FindResource('BaseBrush').Color.ToString()
    $darkDot = $ui.dotConn.Fill.Color.ToString()

    Switch-AppTheme   # Dark -> System
    Assert-Check 'a click on Dark selects System' ($script:ThemeMode -eq 'System' -and $ui.txtThemeName.Text -eq 'System') "$script:ThemeMode"
    Assert-Check 'System uses the Windows app mode' ($script:ThemeName -eq (Get-SystemThemeName)) "$script:ThemeName vs $(Get-SystemThemeName)"
    Assert-Check 'the System choice is saved' ((Test-Path -LiteralPath $settingsFile) -and ((& $savedMode) -eq 'System'))
    Update-SystemTheme -SystemName 'Light'
    Assert-Check 'System follows Windows when it switches to light' ($script:ThemeName -eq 'Light' -and $script:Window.FindResource('BaseBrush').Color.ToString() -eq '#FFFAF4ED') "$script:ThemeName"
    Update-SystemTheme -SystemName 'Dark'
    Assert-Check 'System follows Windows when it switches back to dark' ($script:ThemeName -eq 'Dark' -and $script:Window.FindResource('BaseBrush').Color.ToString() -eq '#FF191724') "$script:ThemeName"

    Switch-AppTheme   # System -> Light
    Assert-Check 'a click on System selects Light' ($script:ThemeMode -eq 'Light' -and $script:ThemeName -eq 'Light' -and $ui.txtThemeName.Text -eq 'Light') "$script:ThemeMode / $script:ThemeName"
    Assert-Check 'light base is Rose Pine Dawn #faf4ed' ($script:Window.FindResource('BaseBrush').Color.ToString() -eq '#FFFAF4ED') $script:Window.FindResource('BaseBrush').Color.ToString()
    Assert-Check 'the window itself follows (DynamicResource)' (([System.Windows.Media.SolidColorBrush]$script:Window.Background).Color.ToString() -eq '#FFFAF4ED') ([System.Windows.Media.SolidColorBrush]$script:Window.Background).Color.ToString()
    Assert-Check 'elements bound from code follow too' ($ui.dotConn.Fill.Color.ToString() -ne $darkDot -and $ui.dotConn.Fill.Color.ToString() -eq '#FFEA9D34') $ui.dotConn.Fill.Color.ToString()
    Assert-Check 'the Light choice is saved' ((& $savedMode) -eq 'Light')
    Update-SystemTheme -SystemName 'Dark'
    Assert-Check 'a fixed mode ignores Windows' ($script:ThemeName -eq 'Light') "$script:ThemeName"
    Save-WindowScreenshot -Path (Join-Path $workDir 'light-theme.png')

    Switch-AppTheme   # Light -> Dark
    Assert-Check 'a click on Light selects Dark and saves it' ($script:ThemeMode -eq 'Dark' -and $script:ThemeName -eq 'Dark' -and (& $savedMode) -eq 'Dark')
    Assert-Check 'dark colors are restored exactly' ($script:Window.FindResource('BaseBrush').Color.ToString() -eq '#FF191724' -and $ui.dotConn.Fill.Color.ToString() -eq $darkDot)
    Assert-Check 'the theme button names the mode and says what a click does' ($ui.btnTheme.ToolTip -like '*Click for System*Ctrl+T*') "$($ui.btnTheme.ToolTip)"

    # ---- step 1: connect
    $ui.txtTenant.Text = 'simulation.invalid'
    Invoke-Connect
    Assert-Check 'connected after Invoke-Connect' $script:Connected
    $savedSettings = Get-Content -LiteralPath $env:PASSKEYPROVISIONER_UISETTINGS -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Check 'the tenant is remembered after a successful connect (and the theme stays)' (($savedSettings.tenant -eq 'simulation.invalid') -and $savedSettings.theme) (($savedSettings | ConvertTo-Json -Compress))
    Assert-Check 'connection chip shows the account' ($ui.txtConn.Text -like '*sim.admin@example.com*') $ui.txtConn.Text
    Assert-Check 'Next is enabled after connecting' $ui.btnNext.IsEnabled
    Assert-Check 'connect button now offers Disconnect' ($ui.btnConnect.Content -eq 'Disconnect')

    # ---- step 2: CSV
    Set-Step 2
    $csv = Join-Path $workDir 'users.csv'
    @(
        'UPN,SerialID'
        'anna.meier@example.com,1001'
        'ben.schulz@example.com,0123456782'
        'carla.nowak@example.com,1003'
        'not-a-upn,1004'
        'dave.koch@example.com,1005'
    ) | Set-Content -LiteralPath $csv -Encoding UTF8
    $ui.rbCsv.IsChecked = $true
    Assert-Check 'CSV panel visible' ($ui.panelCsv.Visibility -eq 'Visible')
    Import-CsvSource -Path $csv
    Assert-Check 'CSV summary counts' ($ui.txtCsvSummary.Text -eq '5 row(s) loaded, 4 valid, 1 invalid') $ui.txtCsvSummary.Text
    Assert-Check 'result path is next to the CSV' ($script:ResultPath -eq (Join-Path $workDir 'users.result.csv')) $script:ResultPath

    # ---- step 3: enroll, with a key swap in the middle
    Assert-Check 'rows built' (New-EnrollRowList)
    Set-Step 3
    Assert-Check 'grid has five rows' ($script:Rows.Count -eq 5) "$($script:Rows.Count)"
    Assert-Check 'invalid row is marked Failed up front' ($script:Rows[3].Status -eq 'Failed' -and $script:Rows[3].Detail -like 'Invalid input*') $script:Rows[3].Detail

    $script:UiTest = @{ Phase = 0; Since = $null; Shot = $false }
    $driver = New-Object System.Windows.Threading.DispatcherTimer
    $driver.Interval = [TimeSpan]::FromMilliseconds(250)
    $driver.Add_Tick({
            $t = $script:UiTest
            if ($ui.bannerKey.Visibility -eq 'Visible') {
                $title = $ui.txtBannerTitle.Text
                if (-not $banners.Contains($title)) { $banners.Add($title) }
                if ($title -like 'Remove the previous key*' -and -not $t.Shot) {
                    $t.Shot = $true
                    Save-WindowScreenshot -Path (Join-Path $workDir 'waiting-for-swap.png')
                }
            }
            if ($t.Phase -eq 0 -and $script:Rows[0].Status -in 'Registered', 'AlreadyRegistered', 'Failed') {
                Set-Content -LiteralPath $simKey -Value '0'      # anna is done: pull the key
                $t.Phase = 1; $t.Since = Get-Date
            } elseif ($t.Phase -eq 1 -and ((Get-Date) - $t.Since).TotalSeconds -gt 5) {
                Set-Content -LiteralPath $simKey -Value '1'      # plug in the next key
                $t.Phase = 2
            }
        })
    $driver.Start()
    Invoke-Enrollment
    $driver.Stop()

    Assert-Check 'anna registered' ($script:Rows[0].Status -eq 'Registered') "$($script:Rows[0].Status) $($script:Rows[0].Detail)"
    Assert-Check 'ben recognized under the legacy name' ($script:Rows[1].Status -eq 'AlreadyRegistered' -and $script:Rows[1].Detail -like '*T2F2-TypeC*') "$($script:Rows[1].Status) $($script:Rows[1].Detail)"
    Assert-Check 'carla failed with the 403 hint' ($script:Rows[2].Status -eq 'Failed' -and $script:Rows[2].Detail -like '*Authentication Administrator*') "$($script:Rows[2].Status) $($script:Rows[2].Detail)"
    Assert-Check 'invalid row stays Failed' ($script:Rows[3].Status -eq 'Failed') $script:Rows[3].Status
    Assert-Check 'dave registered after the key swap' ($script:Rows[4].Status -eq 'Registered') "$($script:Rows[4].Status) $($script:Rows[4].Detail)"
    Assert-Check 'swap banner was shown' ($banners -contains 'Remove the previous key and insert the next one') ($banners -join ' | ')
    Assert-Check 'touch banner was shown' ($banners -contains 'Touch the key') ($banners -join ' | ')
    Assert-Check 'ben did not need the key (no insert banner before ben)' ($banners.Count -ge 2)
    Assert-Check 'phase driver completed the swap' ($script:UiTest.Phase -eq 2) "phase $($script:UiTest.Phase)"
    Assert-Check 'ended on the results step' ($script:Step -eq 4) "step $($script:Step)"
    Assert-Check 'summary tiles' ($ui.txtCountRegistered.Text -eq '2' -and $ui.txtCountAlready.Text -eq '1' -and $ui.txtCountFailed.Text -eq '2') "$($ui.txtCountRegistered.Text)/$($ui.txtCountAlready.Text)/$($ui.txtCountFailed.Text)"
    Save-WindowScreenshot -Path (Join-Path $workDir 'results.png')

    # ---- result file
    $resultPath = Join-Path $workDir 'users.result.csv'
    Assert-Check 'result file written' (Test-Path -LiteralPath $resultPath)
    $result = @(Import-PasskeyProvisionerResult -Path $resultPath)
    Assert-Check 'result file has one record per row' ($result.Count -eq 5) "$($result.Count)"
    $byUpn = @{ }; foreach ($r in $result) { $byUpn[$r.Upn] = $r }
    Assert-Check 'result statuses' ($byUpn['anna.meier@example.com'].Status -eq 'Registered' -and $byUpn['ben.schulz@example.com'].Status -eq 'AlreadyRegistered' -and $byUpn['carla.nowak@example.com'].Status -eq 'Failed' -and $byUpn['dave.koch@example.com'].Status -eq 'Registered') (($result | ForEach-Object { "$($_.Upn)=$($_.Status)" }) -join '; ')
    Assert-Check 'registered rows carry a Graph id' ([bool]$byUpn['anna.meier@example.com'].GraphId -and [bool]$byUpn['dave.koch@example.com'].GraphId)

    # ---- second pass: resume must skip what is done
    Set-Step 2
    $ui.chkResume.IsChecked = $true
    Assert-Check 'rows rebuilt for the resume pass' (New-EnrollRowList)
    $st = @($script:Rows | ForEach-Object { $_.Status })
    Assert-Check 'resume skips anna, ben, dave' ($st[0] -eq 'Skipped' -and $st[1] -eq 'Skipped' -and $st[4] -eq 'Skipped') ($st -join ',')
    Assert-Check 'resume keeps carla pending and the invalid row failed' ($st[2] -eq 'Pending' -and $st[3] -eq 'Failed') ($st -join ',')

    # ---- retry of the failed row works and fails again for the same reason (Graph still denies)
    Set-Step 3
    Invoke-Enrollment
    Assert-Check 'carla fails again after resume pass' ($script:Rows[2].Status -eq 'Failed') $script:Rows[2].Status

    # ---- key management guide (reset countdown, PIN guide)
    Show-ManageGuide -Kind 'Reset'
    Assert-Check 'reset guide opens with the warning' ($ui.panelManage.Visibility -eq 'Visible' -and $ui.txtManageTitle.Text -eq 'Reset the key' -and $ui.txtManageWarning.Visibility -eq 'Visible')
    Assert-Check 'no countdown while the key just stays plugged in' ($ui.panelResetCountdown.Visibility -eq 'Collapsed')
    # a detection gap that is too short for a real removal (Windows talking to the key) must not start the countdown
    $script:KeyPresent = $false; Update-ManageCountdown
    $script:KeyPresent = $true;  Update-ManageCountdown
    Assert-Check 'a very short detection gap does not start the countdown' ($ui.panelResetCountdown.Visibility -eq 'Collapsed')
    Set-Content -LiteralPath $simKey -Value '0'
    Assert-Check 'tool notices the key being pulled' (Wait-Until { -not $script:KeyPresent } 20)
    Assert-Check 'the removal is confirmed after it lasted' (Wait-Until { $script:ManageRemoved } 5)
    Set-Content -LiteralPath $simKey -Value '1'
    Assert-Check 'countdown starts when the key is inserted again' (Wait-Until { $ui.panelResetCountdown.Visibility -eq 'Visible' } 20) $ui.txtResetCountdown.Text
    Assert-Check 'countdown text names the touch and the window' ($ui.txtResetCountdown.Text -like 'Key inserted*touch the key within*' -or $ui.txtResetCountdown.Text -like 'The 10 second window*') $ui.txtResetCountdown.Text
    Save-WindowScreenshot -Path (Join-Path $workDir 'reset-guide.png')
    Open-KeySettings
    Assert-Check 'settings link is only logged in simulation (nothing is opened)' ((@($script:LogEntries | Where-Object { $_.Line -like '*(Simulation) would open ms-settings:signinoptions-launchsecuritykeyenrollment*' })).Count -ge 1)
    Complete-ManageGuide
    Assert-Check 'done closes the guide and points to the Entra cleanup' ($ui.panelManage.Visibility -eq 'Collapsed' -and $ui.txtStatus.Text -like '*old registration in Entra*') $ui.txtStatus.Text
    Show-ManageGuide -Kind 'Pin'
    Assert-Check 'PIN guide has no warning and no countdown' ($ui.txtManageTitle.Text -eq 'Set or change the PIN' -and $ui.txtManageWarning.Visibility -eq 'Collapsed' -and $ui.panelResetCountdown.Visibility -eq 'Collapsed')
    Complete-ManageGuide

    # ---- remove old Entra registrations (anna was registered in this run, ben carries the legacy name)
    $script:AutoConfirm = $true
    $ui.txtCleanUpn.Text = 'anna.meier@example.com'; $ui.txtCleanSerial.Text = ''
    Invoke-CleanupFind
    Assert-Check 'find rejects an empty serial' ($ui.lblCleanInfo.Text -like '*Serial ID is required*' -and -not $ui.btnCleanDelete.IsEnabled) $ui.lblCleanInfo.Text
    $ui.txtCleanSerial.Text = '1001'
    Invoke-CleanupFind
    Assert-Check 'find locates the registration' (@($script:CleanupKeys).Count -eq 1 -and $ui.lblCleanInfo.Text -like 'Found 1*FIDO SECURITY KEY 1001*') $ui.lblCleanInfo.Text
    Assert-Check 'delete button is enabled once something was found' $ui.btnCleanDelete.IsEnabled
    Invoke-CleanupDelete
    Assert-Check 'registration deleted' ($ui.lblCleanInfo.Text -like '1 registration(s) deleted*') $ui.lblCleanInfo.Text
    Invoke-CleanupFind
    Assert-Check 'registration is gone afterwards' (@($script:CleanupKeys).Count -eq 0 -and $ui.lblCleanInfo.Text -like 'No registration*') $ui.lblCleanInfo.Text
    $ui.txtCleanUpn.Text = 'ben.schulz@example.com'; $ui.txtCleanSerial.Text = '0123456782'
    Invoke-CleanupFind
    Assert-Check 'cleanup also finds a legacy name' (@($script:CleanupKeys).Count -eq 1 -and $ui.lblCleanInfo.Text -like '*T2F2-TypeC*') $ui.lblCleanInfo.Text
    Invoke-CleanupDelete
    $logAfter = ($script:LogEntries | ForEach-Object { $_.Line }) -join "`n"
    Assert-Check 'deletions are logged' ($logAfter -like '*Deleted passkey registration*anna.meier@example.com*' -and $logAfter -like '*Deleted passkey registration*ben.schulz@example.com*')
    $script:AutoConfirm = $false

    # ---- pop-up windows are centered on the screen
    # A window of another process that is owned by this window stands in for the Microsoft sign-in dialog.
    $helperPath = Join-Path (Split-Path -Parent $script:AutoRunScript) 'OwnedWindow.ps1'
    $ownerHandle = (Get-AppWindowHandle).ToInt64()
    $findWindow = {
        param($wanted)
        foreach ($h in [PasskeyProvisioner.WindowTools]::VisibleTopLevel()) {
            if ([PasskeyProvisioner.WindowTools]::TitleOf([IntPtr]$h) -eq $wanted) { return [IntPtr]$h }
        }
        return [IntPtr]::Zero
    }
    Start-SignInWatch
    $owned = Start-Process -FilePath powershell.exe -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$helperPath`"", '-OwnerHandle', $ownerHandle, '-Title', 'PasskeyProvisionerSignInProbe')
    $unrelated = Start-Process -FilePath powershell.exe -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$helperPath`"", '-Title', 'PasskeyProvisionerUnrelated')
    $work = [PasskeyProvisioner.WindowTools]::WorkAreaOf((Get-AppWindowHandle))
    $isCentered = {
        Update-SignInWindow
        $w = & $findWindow 'PasskeyProvisionerSignInProbe'
        if ($w -eq [IntPtr]::Zero) { return $false }
        $r = [PasskeyProvisioner.WindowTools]::RectOf($w)
        return ([math]::Abs(($r[0] + $r[2] / 2) - ($work[0] + $work[2] / 2)) -le 6 -and [math]::Abs(($r[1] + $r[3] / 2) - ($work[1] + $work[3] / 2)) -le 6)
    }
    Assert-Check 'a pop-up owned by the tool is centered on the screen' (Wait-Until $isCentered 25) 'no centered probe window found'
    Start-Sleep -Milliseconds 600
    Update-SignInWindow
    $other = & $findWindow 'PasskeyProvisionerUnrelated'
    $otherRect = $(if ($other -ne [IntPtr]::Zero) { [PasskeyProvisioner.WindowTools]::RectOf($other) } else { @(-1, -1, 0, 0) })
    Assert-Check 'an unrelated window of another program is left alone' ($other -ne [IntPtr]::Zero -and $otherRect[0] -le 30 -and $otherRect[1] -le 30) ($otherRect -join ',')
    $popupLog = ($script:LogEntries | ForEach-Object { $_.Line }) -join "`n"
    Assert-Check 'new windows are logged with process, class and owner' ($popupLog -like '*Window opened during sign-in: process powershell*PasskeyProvisionerSignInProbe*owner this window*') 'no log line'
    Assert-Check 'the centered window is logged' ($popupLog -like '*Centered this window on the screen*')
    Assert-Check 'the diagnostic lines do not overwrite the connect status text' ($ui.txtConnectDetail.Text -notlike 'Window opened*')
    foreach ($proc in $owned, $unrelated) { try { $proc.Kill() } catch { $null = $_ } }
    Stop-SignInWatch

    # ---- log content

    $logText = ($script:LogEntries | ForEach-Object { $_.Line }) -join "`n"
    Assert-Check 'log contains the hint' ($logText -like '*Hint:*Authentication Administrator*')
    Assert-Check 'log file exists on disk' (Test-Path -LiteralPath $script:LogFilePath)
    Assert-Check 'log file has content' ((Get-Item -LiteralPath $script:LogFilePath).Length -gt 500)
}
catch {
    Assert-Check 'no unexpected exception' $false ("$_" + "`n" + $_.ScriptStackTrace)
}
finally {
    try { Set-Content -LiteralPath $simKey -Value '1' } catch { $null = $_ }
    $checks | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $outFile -Encoding UTF8
    $script:Window.Close()
}
