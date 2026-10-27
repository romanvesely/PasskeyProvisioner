BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\PasskeyProvisioner.Core\PasskeyProvisioner.Core.psd1') -Force
}

AfterAll {
    Remove-Module PasskeyProvisioner.Core -Force -ErrorAction SilentlyContinue
}

Describe 'Format-PasskeyProvisionerLogLine' {
    It 'formats time, level marker and message' {
        Format-PasskeyProvisionerLogLine -Message 'hello' -Level 'Success' | Should -Match '^\[\d{2}:\d{2}:\d{2}\] \[OK\]  hello$'
        Format-PasskeyProvisionerLogLine 'x' 'Error' | Should -Match '\[ERR\] x$'
        Format-PasskeyProvisionerLogLine 'x' | Should -Match '\[>>\]  x$'
    }
    It 'produces ASCII only' {
        Format-PasskeyProvisionerLogLine -Message 'plain' -Level 'Warning' | Should -Match '^[\x20-\x7E]+$'
    }
}

Describe 'Test-PasskeyProvisionerSerial' {
    It 'rejects empty and whitespace' {
        (Test-PasskeyProvisionerSerial -SerialId '' -Pattern '').Valid | Should -BeFalse
        (Test-PasskeyProvisionerSerial -SerialId '   ' -Pattern '').Valid | Should -BeFalse
        (Test-PasskeyProvisionerSerial -SerialId '' -Pattern '').Message | Should -Be 'Serial ID is required.'
    }
    It 'accepts any non-empty serial, including spaces, when no pattern is configured' {
        (Test-PasskeyProvisionerSerial -SerialId 'TEST KEY' -Pattern '').Valid | Should -BeTrue
    }
    It 'enforces the configured pattern' {
        (Test-PasskeyProvisionerSerial -SerialId '0123456789' -Pattern '^\d{10}$').Valid | Should -BeTrue
        $bad = Test-PasskeyProvisionerSerial -SerialId '12AB' -Pattern '^\d{10}$'
        $bad.Valid | Should -BeFalse
        $bad.Message | Should -Match 'expected format'
    }
    It 'trims before matching' {
        (Test-PasskeyProvisionerSerial -SerialId ' 0123456789 ' -Pattern '^\d{10}$').Valid | Should -BeTrue
    }
}

Describe 'Test-PasskeyProvisionerUpn' {
    It 'accepts normal UPNs' {
        (Test-PasskeyProvisionerUpn -Upn 'test.user@contoso.com').Valid | Should -BeTrue
    }
    It 'rejects missing parts, spaces and empty input' {
        foreach ($u in '', 'no-at-sign', 'a@b', 'a b@c.de', '@c.de', 'a@@c.de') {
            (Test-PasskeyProvisionerUpn -Upn $u).Valid | Should -BeFalse -Because "'$u' is not a valid UPN"
        }
    }
}

Describe 'Get-PasskeyProvisionerResultSummary' {
    It 'counts outcomes' {
        $r = @(
            [pscustomobject]@{ Status = 'Registered' }, [pscustomobject]@{ Status = 'Registered' },
            [pscustomobject]@{ Status = 'AlreadyRegistered' }, [pscustomobject]@{ Status = 'Failed' },
            [pscustomobject]@{ Status = 'Skipped' }
        )
        $s = Get-PasskeyProvisionerResultSummary -Result $r
        $s.Total | Should -Be 5
        $s.Registered | Should -Be 2
        $s.AlreadyRegistered | Should -Be 1
        $s.Failed | Should -Be 1
        $s.Skipped | Should -Be 1
    }
    It 'handles an empty list' {
        (Get-PasskeyProvisionerResultSummary -Result @()).Total | Should -Be 0
    }
}

Describe 'Key swap gate' {
    It 'is ready at once when a key is already plugged in for the first row' {
        (New-PasskeyProvisionerKeyGate -KeyPresent $true).State | Should -Be 'Ready'
    }
    It 'waits for the first key when none is plugged in' {
        $g = New-PasskeyProvisionerKeyGate -KeyPresent $false
        $g.State | Should -Be 'WaitInsert'
        (Update-PasskeyProvisionerKeyGate -Gate $g -KeyPresent $false).State | Should -Be 'WaitInsert'
        (Update-PasskeyProvisionerKeyGate -Gate $g -KeyPresent $true).State | Should -Be 'Ready'
    }
    It 'requires a remove and insert cycle after a key was used' {
        $g = Set-PasskeyProvisionerKeyGateUsed -KeyPresent $true
        $g.State | Should -Be 'WaitRemove'
        # the same key stays plugged in: still blocked, even after many polls
        1..5 | ForEach-Object { $g = Update-PasskeyProvisionerKeyGate -Gate $g -KeyPresent $true }
        $g.State | Should -Be 'WaitRemove'
        # key removed
        $g = Update-PasskeyProvisionerKeyGate -Gate $g -KeyPresent $false
        $g.State | Should -Be 'WaitInsert'
        # next key inserted
        $g = Update-PasskeyProvisionerKeyGate -Gate $g -KeyPresent $true
        $g.State | Should -Be 'Ready'
    }
    It 'goes straight to WaitInsert when the key was already removed after use' {
        (Set-PasskeyProvisionerKeyGateUsed -KeyPresent $false).State | Should -Be 'WaitInsert'
    }
    It 'falls back to WaitInsert when a ready key is pulled' {
        $g = New-PasskeyProvisionerKeyGate -KeyPresent $true
        (Update-PasskeyProvisionerKeyGate -Gate $g -KeyPresent $false).State | Should -Be 'WaitInsert'
    }
}
