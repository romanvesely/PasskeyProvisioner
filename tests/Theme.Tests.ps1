BeforeAll {
    $appDir = Join-Path $PSScriptRoot '..\src\PasskeyProvisioner.App'
    . (Join-Path $appDir 'ThemeMath.ps1')
    $script:Themes = Import-PowerShellDataFile -Path (Join-Path $appDir 'Themes.psd1')
    $script:Roles = 'base', 'surface', 'overlay', 'muted', 'subtle', 'text', 'love', 'gold', 'rose', 'pine', 'foam', 'iris', 'highlightLow', 'highlightMed', 'highlightHigh'
}

Describe 'Color math' {
    It 'parses and formats hex colors' {
        (ConvertFrom-HexColor '#191724') | Should -Be @(25, 23, 36)
        ConvertTo-HexColor @(250, 244, 237) | Should -BeExactly '#faf4ed'
    }
    It 'rejects malformed colors' {
        { ConvertFrom-HexColor 'red' } | Should -Throw '*Not a #rrggbb color*'
        { ConvertFrom-HexColor '#12345' } | Should -Throw
    }
    It 'computes the WCAG contrast ratio' {
        [math]::Round((Get-ContrastRatio -Foreground '#000000' -Background '#ffffff'), 1) | Should -Be 21
        [math]::Round((Get-ContrastRatio -Foreground '#808080' -Background '#808080'), 1) | Should -Be 1
        (Get-ContrastRatio -Foreground '#ffffff' -Background '#000000') | Should -Be (Get-ContrastRatio -Foreground '#000000' -Background '#ffffff')
    }
    It 'blends between two colors' {
        Get-BlendedHex -From '#000000' -To '#ffffff' -Amount 0 | Should -BeExactly '#000000'
        Get-BlendedHex -From '#000000' -To '#ffffff' -Amount 1 | Should -BeExactly '#ffffff'
        Get-BlendedHex -From '#000000' -To '#ffffff' -Amount 0.5 | Should -BeExactly '#808080'
    }
    It 'leaves a color alone when it is already readable' {
        Get-ReadableHex -Color '#e0def4' -Against @('#191724') -Toward '#ffffff' | Should -BeExactly '#e0def4'
    }
    It 'moves a faint color toward the target until the ratio is reached' {
        $result = Get-ReadableHex -Color '#ea9d34' -Against @('#fffaf3') -Toward '#464261' -MinRatio 4.5
        $result | Should -Not -BeExactly '#ea9d34'
        (Get-ContrastRatio -Foreground $result -Background '#fffaf3') | Should -BeGreaterOrEqual 4.5
    }
}

Describe 'Theme palettes' {
    It 'defines <Name> with all 15 Rose Pine roles as valid colors' -ForEach @(@{ Name = 'Dark' }, @{ Name = 'Light' }) {
        $t = $script:Themes[$Name]
        foreach ($role in $script:Roles) {
            $t.ContainsKey($role) | Should -BeTrue -Because "$Name needs the role '$role'"
            $t[$role] | Should -Match '^#[0-9a-f]{6}$' -Because "$Name.$role"
        }
        $t.DisplayName | Should -Not -BeNullOrEmpty
    }
    It 'uses the official Rose Pine colors for dark and Rose Pine Dawn for light' {
        $script:Themes.Dark.IsDark | Should -BeTrue
        $script:Themes.Dark.DisplayName | Should -BeExactly 'Rose Pine'
        $script:Themes.Dark.base | Should -BeExactly '#191724'
        $script:Themes.Dark.iris | Should -BeExactly '#c4a7e7'
        $script:Themes.Light.IsDark | Should -BeFalse
        $script:Themes.Light.DisplayName | Should -BeExactly 'Rose Pine Dawn'
        $script:Themes.Light.base | Should -BeExactly '#faf4ed'
        $script:Themes.Light.text | Should -BeExactly '#464261'
    }
    It 'is not the Moon variant' {
        $script:Themes.Dark.base | Should -Not -BeExactly '#232136'
    }
}

Describe 'Readable colors in <Name>' -ForEach @(@{ Name = 'Dark' }, @{ Name = 'Light' }) {
    BeforeAll {
        $script:T = $script:Themes[$Name]
        $script:R = Get-ThemeReadableColor -Theme $script:T
    }

    It 'primary text is far above the AA threshold' {
        (Get-ContrastRatio -Foreground $script:T.text -Background $script:T.base) | Should -BeGreaterOrEqual 7
        (Get-ContrastRatio -Foreground $script:T.text -Background $script:T.surface) | Should -BeGreaterOrEqual 7
        (Get-ContrastRatio -Foreground $script:T.text -Background $script:T.highlightMed) | Should -BeGreaterOrEqual 4.5
    }
    It 'secondary text reaches 4.5:1 on the base and on surfaces' {
        (Get-ContrastRatio -Foreground $script:R.SubtleBrush -Background $script:T.base) | Should -BeGreaterOrEqual 4.5
        (Get-ContrastRatio -Foreground $script:R.SubtleBrush -Background $script:T.surface) | Should -BeGreaterOrEqual 4.5
    }
    It 'accent text on the base, the surface and its own tint reaches 4.5:1' {
        $tint = $(if ($script:T.IsDark) { 0x2E } else { 0x38 }) / 255.0
        foreach ($accent in 'Love', 'Gold', 'Rose', 'Pine', 'Foam', 'Iris') {
            $text = $script:R[$accent + 'TextBrush']
            $onTint = Get-BlendedHex -From $script:T.surface -To $script:T[$accent.ToLower()] -Amount $tint
            (Get-ContrastRatio -Foreground $text -Background $script:T.base) | Should -BeGreaterOrEqual 4.5 -Because "$accent on base"
            (Get-ContrastRatio -Foreground $text -Background $script:T.surface) | Should -BeGreaterOrEqual 4.5 -Because "$accent on surface"
            (Get-ContrastRatio -Foreground $text -Background $onTint) | Should -BeGreaterOrEqual 4.5 -Because "$accent on its tint"
        }
    }
    It 'the primary button label (base color) is readable on the button face' {
        (Get-ContrastRatio -Foreground $script:T.base -Background $script:R.IrisButtonBrush) | Should -BeGreaterOrEqual 4.5
    }
    It 'keeps the exact palette color for accents that already pass (only faint ones are adjusted)' {
        $changed = @(foreach ($accent in 'Love', 'Gold', 'Rose', 'Pine', 'Foam', 'Iris') {
                if ($script:R[$accent + 'TextBrush'] -ne $script:T[$accent.ToLower()]) { $accent }
            })
        if ($script:T.IsDark) { $changed | Should -Be @('Love', 'Pine') -Because 'pine is too faint on dark surfaces and love on its own tint' }
        else { $changed.Count | Should -BeGreaterThan 0 -Because 'several Dawn accents are too faint as text' }
    }
}
