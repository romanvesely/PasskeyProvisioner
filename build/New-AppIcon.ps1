#Requires -Version 5.1
<#
.SYNOPSIS
    Renders the application icon (assets\app.ico) from the same key glyph the app uses in its navigation rail.
.DESCRIPTION
    Rose Pine iris tile with the key glyph in the dark base color, drawn at 16 to 256 px and packed as PNG frames into one
    .ico. Needs STA (WPF). Run: powershell.exe -STA -NoProfile -File build\New-AppIcon.ps1
#>
[CmdletBinding()]
param([string]$OutPath)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase
if (-not $OutPath) { $OutPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'assets\app.ico' }

$themes = Import-PowerShellDataFile -Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\PasskeyProvisioner.App\Themes.psd1')
$dark = $themes.Dark
$tile = [System.Windows.Media.ColorConverter]::ConvertFromString($dark.iris)
$ink = [System.Windows.Media.ColorConverter]::ConvertFromString($dark.base)

$fontName = 'Segoe Fluent Icons'
if (-not ([System.Windows.Media.Fonts]::SystemFontFamilies | Where-Object { $_.Source -eq $fontName })) { $fontName = 'Segoe MDL2 Assets' }
$typeface = New-Object System.Windows.Media.Typeface($fontName)
$glyph = [string][char]0xE8D7

function Get-IconFrame([int]$Size) {
    $visual = New-Object System.Windows.Media.DrawingVisual
    $dc = $visual.RenderOpen()
    $radius = $Size * 0.22
    $dc.DrawRoundedRectangle([System.Windows.Media.SolidColorBrush]::new($tile), $null, (New-Object System.Windows.Rect 0, 0, $Size, $Size), $radius, $radius)
    $fontSize = $Size * 0.62
    $text = New-Object System.Windows.Media.FormattedText($glyph, [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Windows.FlowDirection]::LeftToRight, $typeface, $fontSize, [System.Windows.Media.SolidColorBrush]::new($ink), 1.0)
    $dc.DrawText($text, (New-Object System.Windows.Point (($Size - $text.Width) / 2), (($Size - $text.Height) / 2)))
    $dc.Close()
    $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($Size, $Size, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $bmp.Render($visual)
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp))
    $ms = New-Object System.IO.MemoryStream
    $enc.Save($ms)
    return , $ms.ToArray()
}

$sizes = 16, 24, 32, 48, 64, 128, 256
$frames = foreach ($s in $sizes) { , (Get-IconFrame $s) }

$out = New-Object System.IO.MemoryStream
$w = New-Object System.IO.BinaryWriter($out)
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $dim = $(if ($sizes[$i] -ge 256) { 0 } else { $sizes[$i] })
    $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([uint16]1); $w.Write([uint16]32)
    $w.Write([uint32]$frames[$i].Length); $w.Write([uint32]$offset)
    $offset += $frames[$i].Length
}
foreach ($f in $frames) { $w.Write($f) }
$w.Flush()
New-Item -ItemType Directory -Path (Split-Path -Parent $OutPath) -Force | Out-Null
[System.IO.File]::WriteAllBytes($OutPath, $out.ToArray())
Write-Output "Wrote $OutPath ($($out.Length) bytes, sizes: $($sizes -join ', '))"
