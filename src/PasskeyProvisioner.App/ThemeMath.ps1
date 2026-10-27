# Color math for the themes. Pure functions on hex strings, no WPF types, so they can be unit tested.
#
# Why this exists: the official Rose Pine palettes are designed for editors and some accents are too faint as text on
# their own backgrounds (for example pine on dark, gold or foam on Dawn). Backgrounds, borders and shapes keep the exact
# palette colors. For text and icons the accent is moved toward the theme's text color, in small steps, until it reaches
# the WCAG AA contrast ratio of 4.5:1 against every background it appears on. Colors that already pass stay unchanged.

function ConvertFrom-HexColor {
    # '#rrggbb' -> @(r, g, b) with 0..255
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Hex)
    $h = $Hex.TrimStart('#')
    if ($h.Length -ne 6 -or $h -notmatch '^[0-9A-Fa-f]{6}$') { throw "Not a #rrggbb color: '$Hex'" }
    @([Convert]::ToInt32($h.Substring(0, 2), 16), [Convert]::ToInt32($h.Substring(2, 2), 16), [Convert]::ToInt32($h.Substring(4, 2), 16))
}

function ConvertTo-HexColor {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int[]]$Rgb)
    '#{0:x2}{1:x2}{2:x2}' -f $Rgb[0], $Rgb[1], $Rgb[2]
}

function Get-RelativeLuminance {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Hex)
    $lin = foreach ($v in (ConvertFrom-HexColor $Hex)) {
        $s = $v / 255.0
        if ($s -le 0.03928) { $s / 12.92 } else { [math]::Pow(($s + 0.055) / 1.055, 2.4) }
    }
    (0.2126 * $lin[0]) + (0.7152 * $lin[1]) + (0.0722 * $lin[2])
}

function Get-ContrastRatio {
    # WCAG contrast ratio, 1..21
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Foreground, [Parameter(Mandatory)][string]$Background)
    $a = Get-RelativeLuminance $Foreground
    $b = Get-RelativeLuminance $Background
    if ($a -lt $b) { $a, $b = $b, $a }
    ($a + 0.05) / ($b + 0.05)
}

function Get-BlendedHex {
    # Mixes From toward To; Amount 0 = From, 1 = To.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$From, [Parameter(Mandatory)][string]$To, [Parameter(Mandatory)][double]$Amount)
    $f = ConvertFrom-HexColor $From
    $t = ConvertFrom-HexColor $To
    $mixed = for ($i = 0; $i -lt 3; $i++) { [int][math]::Round($f[$i] + (($t[$i] - $f[$i]) * $Amount)) }
    ConvertTo-HexColor $mixed
}

function Get-ReadableHex {
    <#
    .SYNOPSIS
        Returns Color, or the lightest/darkest step toward Toward that reaches MinRatio against all Against colors.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Color,
        [Parameter(Mandatory)][string[]]$Against,
        [Parameter(Mandatory)][string]$Toward,
        [double]$MinRatio = 4.5
    )
    for ($step = 0; $step -le 25; $step++) {
        $candidate = Get-BlendedHex -From $Color -To $Toward -Amount ($step * 0.04)
        $worst = ($Against | ForEach-Object { Get-ContrastRatio -Foreground $candidate -Background $_ } | Measure-Object -Minimum).Minimum
        if ($worst -ge $MinRatio) { return $candidate }
    }
    return $Toward
}

function Get-ThemeReadableColor {
    # Readable text colors and the primary button face for a theme (hex per brush key).
    param([Parameter(Mandatory)][hashtable]$Theme)
    $tintFraction = $(if ($Theme.IsDark) { 0x2E } else { 0x38 }) / 255.0
    $result = [ordered]@{}
    foreach ($accent in 'Love', 'Gold', 'Rose', 'Pine', 'Foam', 'Iris') {
        $color = $Theme[$accent.ToLower()]
        $tintOnSurface = Get-BlendedHex -From $Theme.surface -To $color -Amount $tintFraction
        $result[$accent + 'TextBrush'] = Get-ReadableHex -Color $color -Against @($Theme.base, $Theme.surface, $tintOnSurface) -Toward $Theme.text -MinRatio 4.5
    }
    # Secondary text sits on the base and on surfaces.
    $result['SubtleBrush'] = Get-ReadableHex -Color $Theme.subtle -Against @($Theme.base, $Theme.surface) -Toward $Theme.text -MinRatio 4.5
    # The primary button label is drawn in the base color; the button face is iris, darkened only when the label would be too faint.
    $result['IrisButtonBrush'] = Get-ReadableHex -Color $Theme.iris -Against @($Theme.base) -Toward $Theme.text -MinRatio 4.5
    $result
}
