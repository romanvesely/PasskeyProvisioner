# Pure window geometry, unit tested. All values in the same unit (physical pixels).

function Get-CenteredOrigin {
    <#
    .SYNOPSIS
        Top-left position that centers a window of the given size over an outer rectangle, kept inside a work area.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$OuterLeft, [Parameter(Mandatory)][int]$OuterTop,
        [Parameter(Mandatory)][int]$OuterWidth, [Parameter(Mandatory)][int]$OuterHeight,
        [Parameter(Mandatory)][int]$InnerWidth, [Parameter(Mandatory)][int]$InnerHeight,
        [Parameter(Mandatory)][int]$AreaLeft, [Parameter(Mandatory)][int]$AreaTop,
        [Parameter(Mandatory)][int]$AreaWidth, [Parameter(Mandatory)][int]$AreaHeight
    )
    $x = $OuterLeft + [int][math]::Floor(($OuterWidth - $InnerWidth) / 2)
    $y = $OuterTop + [int][math]::Floor(($OuterHeight - $InnerHeight) / 2)
    $maxX = $AreaLeft + $AreaWidth - $InnerWidth
    $maxY = $AreaTop + $AreaHeight - $InnerHeight
    # A window larger than the area is pinned to the top-left corner of the area.
    $x = [math]::Max($AreaLeft, [math]::Min($x, $maxX))
    $y = [math]::Max($AreaTop, [math]::Min($y, $maxY))
    [pscustomobject]@{ X = [int]$x; Y = [int]$y }
}

function Test-RaiseSignInWindow {
    <#
    .SYNOPSIS
        True when the sign-in window has to be brought to the front again: the tool window has just become the foreground
        window while a sign-in window is open (the user clicked the tool or its taskbar button and covered the sign-in window).
    .DESCRIPTION
        Only the change to "tool window in front" counts, so the sign-in window is not pulled forward over and over while
        the tool window stays in front.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool]$ToolIsForeground,
        [Parameter(Mandatory)][bool]$ToolWasForeground,
        [Parameter(Mandatory)][bool]$SignInWindowOpen
    )
    $SignInWindowOpen -and $ToolIsForeground -and -not $ToolWasForeground
}
