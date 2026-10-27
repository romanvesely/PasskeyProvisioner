BeforeAll {
    . (Join-Path $PSScriptRoot '..\src\PasskeyProvisioner.App\WindowMath.ps1')
    # A 1000 x 800 tool window at (100, 100) on a 1920 x 1040 work area, dialog 470 x 555.
    $script:Common = @{
        OuterLeft = 100; OuterTop = 100; OuterWidth = 1000; OuterHeight = 800
        InnerWidth = 470; InnerHeight = 555
        AreaLeft = 0; AreaTop = 0; AreaWidth = 1920; AreaHeight = 1040
    }
}

Describe 'Get-CenteredOrigin' {
    It 'centers the dialog over the tool window' {
        $p = Get-CenteredOrigin @script:Common
        $p.X | Should -Be (100 + [math]::Floor((1000 - 470) / 2))
        $p.Y | Should -Be (100 + [math]::Floor((800 - 555) / 2))
    }
    It 'keeps the dialog inside the work area on the right and bottom' {
        $c = $script:Common.Clone(); $c.OuterLeft = 1700; $c.OuterTop = 900; $c.OuterWidth = 400; $c.OuterHeight = 300
        $p = Get-CenteredOrigin @c
        ($p.X + 470) | Should -BeLessOrEqual 1920
        ($p.Y + 555) | Should -BeLessOrEqual 1040
    }
    It 'keeps the dialog inside the work area on the left and top (second monitor to the left)' {
        $c = $script:Common.Clone(); $c.AreaLeft = -1920; $c.AreaWidth = 1920; $c.OuterLeft = -1900; $c.OuterTop = -10; $c.OuterWidth = 100; $c.OuterHeight = 100
        $p = Get-CenteredOrigin @c
        $p.X | Should -BeGreaterOrEqual -1920
        $p.Y | Should -BeGreaterOrEqual 0
    }
    It 'pins a dialog that is larger than the work area to the corner' {
        $c = $script:Common.Clone(); $c.InnerWidth = 3000; $c.InnerHeight = 2000
        $p = Get-CenteredOrigin @c
        $p.X | Should -Be 0
        $p.Y | Should -Be 0
    }
    It 'returns integers' {
        (Get-CenteredOrigin @script:Common).X | Should -BeOfType [int]
    }
}
