# Manual check of the Windows security key dialog handling with the REAL Windows Settings app. Runs inside the app
# window (dot-sourced by the app). Start it with tests/Invoke-RealDialogTest.ps1.
#
# It opens ms-settings:signinoptions-launchsecuritykeyenrollment, which shows the "Windows Hello setup" dialog. Nothing
# is changed on any key and no Microsoft Graph call is made: the dialog is only opened, photographed and closed again.
# Not part of the automated suite because it needs a real, visible Windows desktop and starts a real system app.

$outFile = $env:PASSKEYPROVISIONER_UITEST_OUT
$workDir = $env:PASSKEYPROVISIONER_UITEST_DIR
$checks = New-Object System.Collections.Generic.List[object]

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

function Save-ScreenCapture {
    param([string]$Path)
    Add-Type -AssemblyName System.Drawing
    $w = [PasskeyProvisioner.WindowTools]::WorkAreaOf((Get-AppWindowHandle))
    $bmp = New-Object System.Drawing.Bitmap($w[2], $w[3])
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($w[0], $w[1], 0, 0, $bmp.Size)
    $g.Dispose()
    $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}

function Get-NewFrameWindow {
    # New Windows Settings style windows only: other programs may open windows while the test runs (Notepad, TeamViewer, ...).
    param([long[]]$Before)
    @([PasskeyProvisioner.WindowTools]::VisibleTopLevel() | Where-Object { $Before -notcontains $_ -and [PasskeyProvisioner.WindowTools]::ClassName([IntPtr][long]$_) -eq 'ApplicationFrameWindow' })
}

function Get-LeftoverText {
    param([object[]]$Handles)
    $parts = foreach ($h in @($Handles)) {
        $p = [IntPtr][long]$h
        "'{0}' class {1} pid {2}" -f [PasskeyProvisioner.WindowTools]::TitleOf($p), [PasskeyProvisioner.WindowTools]::ClassName($p), [PasskeyProvisioner.WindowTools]::ProcessIdOf($p)
    }
    ($parts -join '; ')
}

try {
    $before = @([PasskeyProvisioner.WindowTools]::VisibleTopLevel())
    Show-ManageGuide -Kind 'Reset'
    [PasskeyProvisioner.WindowTools]::BringToFront((Get-AppWindowHandle))
    Open-KeySettings
    Assert-Check 'the large Settings window was made transparent as soon as it appeared (never seen)' ([PasskeyProvisioner.WindowTools]::IsInvisible($script:KeyDialogOwner))

    Assert-Check 'the small Windows dialog was found' ([PasskeyProvisioner.WindowTools]::IsVisibleWindow($script:KeyDialog))
    Assert-Check 'the large Settings window was found and hidden off screen' (($script:KeyDialogOwner -ne [IntPtr]::Zero) -and ([PasskeyProvisioner.WindowTools]::RectOf($script:KeyDialogOwner)[0] -le -30000)) "$([PasskeyProvisioner.WindowTools]::RectOf($script:KeyDialogOwner) -join ',')"
    Assert-Check 'the Settings window is recognized by its process (language independent)' ([PasskeyProvisioner.WindowTools]::HostsProcess($script:KeyDialogOwner, 'SystemSettings')) "owner class $([PasskeyProvisioner.WindowTools]::ClassName($script:KeyDialogOwner))"
    $work = [PasskeyProvisioner.WindowTools]::WorkAreaOf((Get-AppWindowHandle))
    $dlg = [PasskeyProvisioner.WindowTools]::RectOf($script:KeyDialog)
    $cx = $dlg[0] + ($dlg[2] / 2); $cy = $dlg[1] + ($dlg[3] / 2)
    $openedOwner = $script:KeyDialogOwner
    Assert-Check 'the dialog is centered on the screen' ([math]::Abs($cx - ($work[0] + $work[2] / 2)) -le 6 -and [math]::Abs($cy - ($work[1] + $work[3] / 2)) -le 6) "dialog $($dlg -join ',') work area $($work -join ',')"
    Start-Sleep -Milliseconds 800
    Save-ScreenCapture -Path (Join-Path $workDir 'dialog-on-screen.png')

    # the dialog is brought back to the front when the button is pressed again
    Open-KeySettings
    Assert-Check 'a second click reuses the open dialog (no second Settings window)' ((Get-NewFrameWindow $before).Count -le 2)

    Complete-ManageGuide
    Assert-Check 'Done closes the dialog' (Wait-Until { -not [PasskeyProvisioner.WindowTools]::IsVisibleWindow($script:KeyDialog) } 5)
    [void](Wait-Until { (Get-NewFrameWindow $before).Count -eq 0 } 6)
    Assert-Check 'the hidden Settings window was closed together with the dialog' (-not [PasskeyProvisioner.WindowTools]::IsVisibleWindow($openedOwner)) 'the off-screen Settings window is still open'
    $leftover = @(Get-NewFrameWindow $before)
    Assert-Check 'no new Settings style window is left behind' ($leftover.Count -eq 0) (Get-LeftoverText $leftover)

    # second round: the user closes the dialog himself -> the hidden Settings window must be closed by the tool
    Show-ManageGuide -Kind 'Pin'
    Open-KeySettings
    Assert-Check 'second round: dialog found' ([PasskeyProvisioner.WindowTools]::IsVisibleWindow($script:KeyDialog))
    $openedOwner2 = $script:KeyDialogOwner
    [PasskeyProvisioner.WindowTools]::Close($script:KeyDialog)   # same as the user clicking the X
    Assert-Check 'second round: the tool notices the closed dialog and cleans up' (Wait-Until { $script:KeyDialog -eq [IntPtr]::Zero } 10)
    [void](Wait-Until { (Get-NewFrameWindow $before).Count -eq 0 } 6)
    $leftover = @(Get-NewFrameWindow $before)
    Assert-Check 'second round: the hidden Settings window was closed too' (-not [PasskeyProvisioner.WindowTools]::IsVisibleWindow($openedOwner2)) 'the off-screen Settings window is still open'
    Assert-Check 'second round: no new Settings style window is left behind' ($leftover.Count -eq 0) (Get-LeftoverText $leftover)
    Hide-ManageGuide
}
catch {
    Assert-Check 'no unexpected exception' $false ("$_" + "`n" + $_.ScriptStackTrace)
}
finally {
    try { Close-KeyDialogHost -CloseDialog } catch { $null = $_ }
    $checks | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $outFile -Encoding UTF8
    $script:Window.Close()
}
