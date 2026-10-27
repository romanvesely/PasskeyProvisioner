BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..\src\PasskeyProvisioner.Core\PasskeyProvisioner.Core.psd1'
    Import-Module $script:ModulePath -Force
    $script:FixtureDir = Join-Path $PSScriptRoot 'fixtures'

    function ConvertFrom-Base64Url {
        param([string]$Text)
        $s = $Text.Replace('-', '+').Replace('_', '/')
        switch ($s.Length % 4) { 2 { $s += '==' } 3 { $s += '=' } }
        , [System.Convert]::FromBase64String($s)
    }

    # Stand-ins for commands that live in modules which are not loaded during unit tests. Parameters are declared so
    # that Mock -ParameterFilter can bind them.
    Set-Item -Path Function:\global:Get-PasskeyRegistrationOptions -Value { param($UserId) $null = $UserId }
    Set-Item -Path Function:\global:New-Passkey -Value { param([Parameter(ValueFromPipeline)]$Options) process { $null = $Options } }
    Set-Item -Path Function:\global:Invoke-MgGraphRequest -Value { param($Uri, $Method, $Body, $ContentType) $null = $Uri, $Method, $Body, $ContentType }
    Set-Item -Path Function:\global:Get-MgUserAuthenticationFido2Method -Value { param($UserId) $null = $UserId }
    Set-Item -Path Function:\global:Get-MgBetaUserAuthenticationFido2Method -Value { param($UserId) $null = $UserId }
    Set-Item -Path Function:\global:Remove-MgUserAuthenticationFido2Method -Value { param($UserId, $Fido2AuthenticationMethodId) $null = $UserId, $Fido2AuthenticationMethodId }
    Set-Item -Path Function:\global:Remove-MgBetaUserAuthenticationFido2Method -Value { param($UserId, $Fido2AuthenticationMethodId) $null = $UserId, $Fido2AuthenticationMethodId }

    # Complete configuration object as the module produces it (StrictMode is on in the module).
    function Get-TestConfig {
        param([string]$ApiVersion = 'v1.0')
        [pscustomobject]@{
            displayNamePrefix         = 'FIDO SECURITY KEY'
            legacyDisplayNamePrefixes = @('T2F2-TypeC')
            graphApiVersion           = $ApiVersion
        }
    }
}

AfterAll {
    Set-PasskeyProvisionerLogSink
    Stop-PasskeyProvisionerLogFile
    foreach ($f in 'Get-PasskeyRegistrationOptions', 'New-Passkey', 'Invoke-MgGraphRequest', 'Get-MgUserAuthenticationFido2Method', 'Get-MgBetaUserAuthenticationFido2Method', 'Remove-MgUserAuthenticationFido2Method', 'Remove-MgBetaUserAuthenticationFido2Method') {
        Remove-Item "Function:\$f" -ErrorAction SilentlyContinue
    }
    Remove-Module PasskeyProvisioner.Core -Force -ErrorAction SilentlyContinue
}

Describe 'ConvertTo-Base64Url' {
    It 'uses the URL-safe alphabet without padding' {
        ConvertTo-Base64Url -Bytes ([byte[]](251, 255, 254, 0)) | Should -BeExactly '-__-AA'
    }
    It 'round-trips arbitrary bytes' {
        $bytes = [byte[]](0..255)
        $enc = ConvertTo-Base64Url -Bytes $bytes
        $enc | Should -Not -Match '[+/=]'
        (ConvertFrom-Base64Url $enc) | Should -Be $bytes
    }
    It 'handles one, two and three byte inputs (all padding cases)' {
        ConvertTo-Base64Url -Bytes ([byte[]](1)) | Should -BeExactly 'AQ'
        ConvertTo-Base64Url -Bytes ([byte[]](1, 2)) | Should -BeExactly 'AQI'
        ConvertTo-Base64Url -Bytes ([byte[]](1, 2, 3)) | Should -BeExactly 'AQID'
    }
}

Describe 'New-PasskeyProvisionerGraphBody' {
    BeforeAll {
        $fixture = Get-Content (Join-Path $script:FixtureDir 'graph-body.json') -Raw | ConvertFrom-Json
        $script:Passkey = [pscustomobject]@{
            Id       = ConvertFrom-Base64Url $fixture.publicKeyCredential.id
            Response = (@{
                    clientDataJSON    = $fixture.publicKeyCredential.response.clientDataJSON
                    attestationObject = $fixture.publicKeyCredential.response.attestationObject
                } | ConvertTo-Json -Compress)
        }
        $script:Expected = ((Get-Content (Join-Path $script:FixtureDir 'graph-body.json') -Raw) -replace "`r`n", "`n").TrimEnd()
    }

    It 'matches the recorded fixture exactly' {
        $body = New-PasskeyProvisionerGraphBody -Passkey $script:Passkey -DisplayName 'FIDO SECURITY KEY TEST KEY'
        (($body -replace "`r`n", "`n").TrimEnd()) | Should -BeExactly $script:Expected
    }
    It 'produces valid JSON with the shape Graph expects' {
        $obj = New-PasskeyProvisionerGraphBody -Passkey $script:Passkey -DisplayName 'x' | ConvertFrom-Json
        $obj.displayName | Should -BeExactly 'x'
        $obj.publicKeyCredential.id | Should -Not -BeNullOrEmpty
        $obj.publicKeyCredential.response.clientDataJSON | Should -Not -BeNullOrEmpty
        $obj.publicKeyCredential.response.attestationObject | Should -Not -BeNullOrEmpty
    }
    It 'escapes quotes and backslashes in the display name' {
        $name = 'KEY "A" \ B'
        $obj = New-PasskeyProvisionerGraphBody -Passkey $script:Passkey -DisplayName $name | ConvertFrom-Json
        $obj.displayName | Should -BeExactly $name
    }
    It 'encodes the credential id as Base64Url without padding' {
        $obj = New-PasskeyProvisionerGraphBody -Passkey $script:Passkey -DisplayName 'x' | ConvertFrom-Json
        $obj.publicKeyCredential.id | Should -Not -Match '[+/=]'
    }
}

Describe 'Get-PasskeyProvisionerConfig' {
    BeforeAll {
        $script:Tmp = Join-Path ([IO.Path]::GetTempPath()) ("passkeyprovisioner-tests-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Tmp | Out-Null
    }
    AfterAll { Remove-Item $script:Tmp -Recurse -Force -ErrorAction SilentlyContinue }

    It 'returns the built-in defaults when no file is given' {
        $cfg = Get-PasskeyProvisionerConfig -Refresh
        $cfg.tenantId | Should -BeNullOrEmpty
        $cfg.displayNamePrefix | Should -BeExactly 'FIDO SECURITY KEY'
        $cfg.legacyDisplayNamePrefixes | Should -Contain 'T2F2-TypeC'
        $cfg.graphApiVersion | Should -BeExactly 'v1.0'
        @($cfg.activeModules.Keys) | Should -Not -Contain 'Microsoft.Graph.Beta.Identity.SignIns'
        $cfg.modules['DSInternals.Passkeys'] | Should -BeExactly '3.2.0'
        $cfg.modules['Microsoft.Graph.Authentication'] | Should -BeExactly '2.39.0'
    }
    It 'merges an override file over the defaults and keeps untouched keys' {
        $file = Join-Path $script:Tmp 'a.json'
        '{ "tenantId": "contoso.onmicrosoft.com", "modules": { "DSInternals.Passkeys": "9.9.9" } }' | Set-Content $file -Encoding UTF8
        $cfg = Get-PasskeyProvisionerConfig -Path $file -Refresh
        $cfg.tenantId | Should -BeExactly 'contoso.onmicrosoft.com'
        $cfg.modules['DSInternals.Passkeys'] | Should -BeExactly '9.9.9'
        $cfg.modules['Microsoft.Graph.Authentication'] | Should -BeExactly '2.39.0'
        $cfg.displayNamePrefix | Should -BeExactly 'FIDO SECURITY KEY'
    }
    It 'expands environment variables in the log directory' {
        $file = Join-Path $script:Tmp 'b.json'
        '{ "logDirectory": "%TEMP%\\fidologs" }' | Set-Content $file -Encoding UTF8
        (Get-PasskeyProvisionerConfig -Path $file -Refresh).logDirectory | Should -BeExactly (Join-Path $env:TEMP 'fidologs')
    }
    It 'throws for an explicit path that does not exist' {
        { Get-PasskeyProvisionerConfig -Path (Join-Path $script:Tmp 'missing.json') } | Should -Throw '*not found*'
    }
    It 'throws a clear error for invalid JSON' {
        $file = Join-Path $script:Tmp 'bad.json'
        '{ not json' | Set-Content $file -Encoding UTF8
        { Get-PasskeyProvisionerConfig -Path $file -Refresh } | Should -Throw '*not valid JSON*'
    }
    It 'selects the beta sign-ins module for graphApiVersion beta' {
        $file = Join-Path $script:Tmp 'beta.json'
        '{ "graphApiVersion": "beta" }' | Set-Content $file -Encoding UTF8
        $active = (Get-PasskeyProvisionerConfig -Path $file -Refresh).activeModules
        @($active.Keys) | Should -Contain 'Microsoft.Graph.Beta.Identity.SignIns'
        @($active.Keys) | Should -Not -Contain 'Microsoft.Graph.Identity.SignIns'
    }
    It 'selects the v1.0 sign-ins module and drops the beta module for graphApiVersion v1.0' {
        $file = Join-Path $script:Tmp 'v1.json'
        '{ "graphApiVersion": "v1.0" }' | Set-Content $file -Encoding UTF8
        $active = (Get-PasskeyProvisionerConfig -Path $file -Refresh).activeModules
        @($active.Keys) | Should -Contain 'Microsoft.Graph.Identity.SignIns'
        @($active.Keys) | Should -Not -Contain 'Microsoft.Graph.Beta.Identity.SignIns'
        @($active.Keys) | Should -Contain 'Microsoft.Graph.Authentication'
        @($active.Keys) | Should -Contain 'DSInternals.Passkeys'
    }
    It 'rejects an unknown graphApiVersion' {
        $file = Join-Path $script:Tmp 'badver.json'
        '{ "graphApiVersion": "v2" }' | Set-Content $file -Encoding UTF8
        { Get-PasskeyProvisionerConfig -Path $file -Refresh } | Should -Throw '*Invalid graphApiVersion*'
    }
    It 'ships a valid sample configuration that loads' {
        $sample = Join-Path $PSScriptRoot '..\config\settings.sample.json'
        $cfg = Get-PasskeyProvisionerConfig -Path $sample -Refresh
        $cfg.tenantId | Should -Not -BeNullOrEmpty
        $cfg.logDirectory | Should -Match 'PasskeyProvisioner'
        @($cfg.activeModules.Keys).Count | Should -Be 3
    }
}

Describe 'Get-PasskeyProvisionerDisplayName' {
    It 'joins prefix and serial with a single space' {
        Get-PasskeyProvisionerDisplayName -SerialId '0123456789' -Prefix 'FIDO SECURITY KEY' | Should -BeExactly 'FIDO SECURITY KEY 0123456789'
    }
    It 'keeps serials that contain spaces' {
        Get-PasskeyProvisionerDisplayName -SerialId 'TEST KEY' -Prefix 'FIDO SECURITY KEY' | Should -BeExactly 'FIDO SECURITY KEY TEST KEY'
    }
}

Describe 'Get-PasskeyProvisionerDisplayNameCandidate' {
    It 'lists the current prefix first, then the legacy prefixes' {
        $c = @(Get-PasskeyProvisionerDisplayNameCandidate -SerialId '123' -Config (Get-TestConfig))
        $c | Should -Be @('FIDO SECURITY KEY 123', 'T2F2-TypeC 123')
    }
    It 'does not list duplicates' {
        $cfg = [pscustomobject]@{ displayNamePrefix = 'A'; legacyDisplayNamePrefixes = @('A', 'B'); graphApiVersion = 'beta' }
        @(Get-PasskeyProvisionerDisplayNameCandidate -SerialId '1' -Config $cfg).Count | Should -Be 2
    }
}

Describe 'Get-PasskeyProvisionerRegisteredKey' {
    BeforeEach { Mock -ModuleName PasskeyProvisioner.Core Write-PasskeyProvisionerLog { } }

    It 'finds a key registered under the legacy prefix' {
        Mock -ModuleName PasskeyProvisioner.Core Get-PasskeyProvisionerUserKey { @([pscustomobject]@{ Id = 'k1'; DisplayName = 'T2F2-TypeC 123' }) }
        @(Get-PasskeyProvisionerRegisteredKey -Upn 'u@x.de' -SerialId '123' -Config (Get-TestConfig)).Count | Should -Be 1
    }
    It 'finds a key registered under the current prefix' {
        Mock -ModuleName PasskeyProvisioner.Core Get-PasskeyProvisionerUserKey { @([pscustomobject]@{ Id = 'k1'; DisplayName = 'FIDO SECURITY KEY 123' }) }
        @(Get-PasskeyProvisionerRegisteredKey -Upn 'u@x.de' -SerialId '123' -Config (Get-TestConfig)).Count | Should -Be 1
    }
    It 'does not match a different serial or an unrelated name' {
        Mock -ModuleName PasskeyProvisioner.Core Get-PasskeyProvisionerUserKey {
            @([pscustomobject]@{ Id = 'k1'; DisplayName = 'T2F2-TypeC 999' }, [pscustomobject]@{ Id = 'k2'; DisplayName = 'My phone' })
        }
        @(Get-PasskeyProvisionerRegisteredKey -Upn 'u@x.de' -SerialId '123' -Config (Get-TestConfig)).Count | Should -Be 0
    }
}

Describe 'Get-PasskeyProvisionerUserKey' {
    BeforeEach {
        Mock -ModuleName PasskeyProvisioner.Core Write-PasskeyProvisionerLog { }
        Mock -ModuleName PasskeyProvisioner.Core Get-MgUserAuthenticationFido2Method { @([pscustomobject]@{ Id = 'v1' }) }
        Mock -ModuleName PasskeyProvisioner.Core Get-MgBetaUserAuthenticationFido2Method { @([pscustomobject]@{ Id = 'beta' }) }
    }

    It 'uses the beta cmdlet for graphApiVersion beta' {
        (Get-PasskeyProvisionerUserKey -Upn 'u@x.de' -Config (Get-TestConfig 'beta')).Id | Should -BeExactly 'beta'
        Should -Invoke -ModuleName PasskeyProvisioner.Core Get-MgUserAuthenticationFido2Method -Times 0 -Exactly
    }
    It 'uses the v1.0 cmdlet for graphApiVersion v1.0' {
        (Get-PasskeyProvisionerUserKey -Upn 'u@x.de' -Config (Get-TestConfig 'v1.0')).Id | Should -BeExactly 'v1'
        Should -Invoke -ModuleName PasskeyProvisioner.Core Get-MgBetaUserAuthenticationFido2Method -Times 0 -Exactly
    }
    It 'logs a hint and rethrows on an access denied error' {
        Mock -ModuleName PasskeyProvisioner.Core Get-MgBetaUserAuthenticationFido2Method { throw 'Request Authorization failed (accessDenied)' }
        { Get-PasskeyProvisionerUserKey -Upn 'u@x.de' -Config (Get-TestConfig 'beta') } | Should -Throw '*Authorization failed*'
        Should -Invoke -ModuleName PasskeyProvisioner.Core Write-PasskeyProvisionerLog -ParameterFilter { $Message -like 'Hint:*Authentication Administrator*' }
    }
}

Describe 'Get-PasskeyProvisionerErrorHint' {
    It 'explains 403 / accessDenied with the role requirements' {
        Get-PasskeyProvisionerErrorHint -Text '{"error":{"code":"accessDenied","message":"Request Authorization failed"}}' | Should -Match 'Authentication Administrator'
        Get-PasskeyProvisionerErrorHint -Text 'HTTP/1.1 403 Forbidden' | Should -Match 'Privileged Authentication Administrator'
    }
    It 'explains 401' {
        Get-PasskeyProvisionerErrorHint -Text 'InvalidAuthenticationToken' | Should -Match 'sign in again'
    }
    It 'returns nothing for unrelated errors' {
        Get-PasskeyProvisionerErrorHint -Text 'The connection was closed' | Should -BeNullOrEmpty
        Get-PasskeyProvisionerErrorHint -Text '' | Should -BeNullOrEmpty
    }
}

Describe 'New-PasskeyProvisionerPasskeyRegistration' {
    BeforeAll {
        $fixture = Get-Content (Join-Path $script:FixtureDir 'graph-body.json') -Raw | ConvertFrom-Json
        $script:FakePasskey = [pscustomobject]@{
            Id       = ConvertFrom-Base64Url $fixture.publicKeyCredential.id
            Response = (@{
                    clientDataJSON    = $fixture.publicKeyCredential.response.clientDataJSON
                    attestationObject = $fixture.publicKeyCredential.response.attestationObject
                } | ConvertTo-Json -Compress)
        }
    }
    BeforeEach {
        Mock -ModuleName PasskeyProvisioner.Core Write-PasskeyProvisionerLog { }
        Mock -ModuleName PasskeyProvisioner.Core Get-PasskeyRegistrationOptions { 'options' }
        Mock -ModuleName PasskeyProvisioner.Core New-Passkey { $script:FakePasskey }
        Mock -ModuleName PasskeyProvisioner.Core Invoke-MgGraphRequest { [pscustomobject]@{ id = 'new1'; displayName = 'FIDO SECURITY KEY TEST KEY' } }
    }

    It 'posts the manual body to the beta endpoint with an escaped user id' {
        InModuleScope PasskeyProvisioner.Core { New-PasskeyProvisionerPasskeyRegistration -Upn 'test.user@contoso.com' -DisplayName 'FIDO SECURITY KEY TEST KEY' -ApiVersion 'beta' } | Out-Null
        Should -Invoke -ModuleName PasskeyProvisioner.Core Invoke-MgGraphRequest -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://graph.microsoft.com/beta/users/test.user%40contoso.com/authentication/fido2Methods' -and
            $Method -eq 'POST' -and $ContentType -eq 'application/json' -and
            (($Body | ConvertFrom-Json).displayName -eq 'FIDO SECURITY KEY TEST KEY') -and
            (($Body | ConvertFrom-Json).publicKeyCredential.id -eq 'pgIfj2fnom8rJdb4_h1gKqDkq-gxHFksI-m2aR5T-PNNycBfENAM4ksEBvoXky6d')
        }
    }
    It 'posts to the v1.0 endpoint when requested' {
        InModuleScope PasskeyProvisioner.Core { New-PasskeyProvisionerPasskeyRegistration -Upn 'a@b.de' -DisplayName 'N' -ApiVersion 'v1.0' } | Out-Null
        Should -Invoke -ModuleName PasskeyProvisioner.Core Invoke-MgGraphRequest -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://graph.microsoft.com/v1.0/users/a%40b.de/authentication/fido2Methods'
        }
    }
    It 'logs the error and a hint, then rethrows when Graph denies access' {
        Mock -ModuleName PasskeyProvisioner.Core Invoke-MgGraphRequest { throw 'accessDenied: Request Authorization failed' }
        { InModuleScope PasskeyProvisioner.Core { New-PasskeyProvisionerPasskeyRegistration -Upn 'a@b.de' -DisplayName 'N' } } | Should -Throw '*Authorization failed*'
        Should -Invoke -ModuleName PasskeyProvisioner.Core Write-PasskeyProvisionerLog -ParameterFilter { $Message -like 'Hint:*' }
    }
}

Describe 'Import-PasskeyProvisionerCsv' {
    BeforeAll {
        $script:Tmp = Join-Path ([IO.Path]::GetTempPath()) ("passkeyprovisioner-csv-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Tmp | Out-Null
    }
    AfterAll { Remove-Item $script:Tmp -Recurse -Force -ErrorAction SilentlyContinue }

    It 'reads rows and trims values' {
        $f = Join-Path $script:Tmp 'ok.csv'
        "UPN,SerialID`r`n a@x.de , 123 `r`nb@x.de,456" | Set-Content $f -Encoding UTF8
        $rows = @(Import-PasskeyProvisionerCsv -Path $f)
        $rows.Count | Should -Be 2
        $rows[0].UPN | Should -BeExactly 'a@x.de'
        $rows[0].SerialID | Should -BeExactly '123'
    }
    It 'reads a single-row file as an array of one' {
        $f = Join-Path $script:Tmp 'one.csv'
        "UPN,SerialID`r`na@x.de,1" | Set-Content $f -Encoding UTF8
        @(Import-PasskeyProvisionerCsv -Path $f).Count | Should -Be 1
    }
    It 'accepts the UTF-8 BOM used by the sample file' {
        $f = Join-Path $script:Tmp 'bom.csv'
        [IO.File]::WriteAllText($f, "UPN,SerialID`r`na@x.de,1`r`n", (New-Object Text.UTF8Encoding $true))
        (Import-PasskeyProvisionerCsv -Path $f)[0].UPN | Should -BeExactly 'a@x.de'
    }
    It 'rejects a file without the required columns' {
        $f = Join-Path $script:Tmp 'cols.csv'
        "Mail,Serial`r`na@x.de,1" | Set-Content $f -Encoding UTF8
        { Import-PasskeyProvisionerCsv -Path $f } | Should -Throw "*'UPN' and 'SerialID'*"
    }
    It 'rejects an empty file' {
        $f = Join-Path $script:Tmp 'empty.csv'
        "UPN,SerialID" | Set-Content $f -Encoding UTF8
        { Import-PasskeyProvisionerCsv -Path $f } | Should -Throw '*empty*'
    }
    It 'loads the shipped sample file' {
        @(Import-PasskeyProvisionerCsv -Path (Join-Path $PSScriptRoot '..\samples\users.sample.csv')).Count | Should -BeGreaterThan 0
    }
}

Describe 'Result file' {
    BeforeAll {
        $script:Tmp = Join-Path ([IO.Path]::GetTempPath()) ("passkeyprovisioner-res-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Tmp | Out-Null
    }
    AfterAll { Remove-Item $script:Tmp -Recurse -Force -ErrorAction SilentlyContinue }

    It 'derives users.result.csv from users.csv in the same folder' {
        Get-PasskeyProvisionerResultPath -CsvPath (Join-Path $script:Tmp 'users.csv') | Should -BeExactly (Join-Path $script:Tmp 'users.result.csv')
    }
    It 'round-trips records including an error text with commas and quotes' {
        $path = Join-Path $script:Tmp 'r.result.csv'
        $recs = @(
            (New-PasskeyProvisionerResultRecord -Upn 'a@x.de' -SerialId '1' -Status 'Registered' -GraphId 'g1'),
            (New-PasskeyProvisionerResultRecord -Upn 'b@x.de' -SerialId '2' -Status 'Failed' -ErrorMessage 'bad, "quoted" error')
        )
        Export-PasskeyProvisionerResult -Result $recs -Path $path
        $back = @(Import-PasskeyProvisionerResult -Path $path)
        $back.Count | Should -Be 2
        $back[0].GraphId | Should -BeExactly 'g1'
        $back[1].Error | Should -BeExactly 'bad, "quoted" error'
        ($back[0].PSObject.Properties.Name) | Should -Be @('Upn', 'SerialId', 'Status', 'GraphId', 'Timestamp', 'Error')
    }
    It 'returns an empty list for a missing file' {
        @(Import-PasskeyProvisionerResult -Path (Join-Path $script:Tmp 'nope.csv')).Count | Should -Be 0
    }
    It 'treats Registered and AlreadyRegistered as done and everything else as open' {
        $prev = @(
            (New-PasskeyProvisionerResultRecord -Upn 'a@x.de' -SerialId '1' -Status 'Registered'),
            (New-PasskeyProvisionerResultRecord -Upn 'b@x.de' -SerialId '2' -Status 'AlreadyRegistered'),
            (New-PasskeyProvisionerResultRecord -Upn 'c@x.de' -SerialId '3' -Status 'Failed'),
            (New-PasskeyProvisionerResultRecord -Upn 'd@x.de' -SerialId '4' -Status 'WhatIf')
        )
        Test-PasskeyProvisionerResultDone -Result $prev -Upn 'a@x.de' -SerialId '1' | Should -BeTrue
        Test-PasskeyProvisionerResultDone -Result $prev -Upn 'b@x.de' -SerialId '2' | Should -BeTrue
        Test-PasskeyProvisionerResultDone -Result $prev -Upn 'c@x.de' -SerialId '3' | Should -BeFalse
        Test-PasskeyProvisionerResultDone -Result $prev -Upn 'd@x.de' -SerialId '4' | Should -BeFalse
        Test-PasskeyProvisionerResultDone -Result $prev -Upn 'a@x.de' -SerialId '999' | Should -BeFalse
        Test-PasskeyProvisionerResultDone -Result @() -Upn 'a@x.de' -SerialId '1' | Should -BeFalse
    }
}

Describe 'Test-ModuleVersionConflict' {
    BeforeAll {
        New-Module -Name 'PasskeyProvisionerFakeMod' -ScriptBlock { } | Import-Module -Force
    }
    AfterAll { Remove-Module PasskeyProvisionerFakeMod -Force -ErrorAction SilentlyContinue }

    It 'returns the loaded version when it differs from the required one' {
        InModuleScope PasskeyProvisioner.Core {
            (Test-ModuleVersionConflict -Name 'PasskeyProvisionerFakeMod' -RequiredVersion '1.2.3') | Should -Be ([version]'0.0')
        }
    }
    It 'returns nothing when the loaded version matches' {
        InModuleScope PasskeyProvisioner.Core {
            Test-ModuleVersionConflict -Name 'PasskeyProvisionerFakeMod' -RequiredVersion '0.0' | Should -BeNullOrEmpty
        }
    }
    It 'returns nothing when the module is not loaded' {
        InModuleScope PasskeyProvisioner.Core {
            Test-ModuleVersionConflict -Name 'PasskeyProvisionerNotLoaded' -RequiredVersion '1.0.0' | Should -BeNullOrEmpty
        }
    }
}

Describe 'Initialize-PasskeyProvisionerModules' {
    It 'fails fast when a different version is already loaded' {
        New-Module -Name 'PasskeyProvisionerFakeMod' -ScriptBlock { } | Import-Module -Force
        try {
            $cfg = [pscustomobject]@{ activeModules = [ordered]@{ 'PasskeyProvisionerFakeMod' = '1.2.3' } }
            Mock -ModuleName PasskeyProvisioner.Core Install-PasskeyProvisionerRequiredModule { }
            Mock -ModuleName PasskeyProvisioner.Core Import-Module { }
            Mock -ModuleName PasskeyProvisioner.Core Write-PasskeyProvisionerLog { }
            { Initialize-PasskeyProvisionerModules -Config $cfg } | Should -Throw '*already loaded*'
            Should -Not -Invoke -ModuleName PasskeyProvisioner.Core Import-Module
        } finally {
            Remove-Module PasskeyProvisionerFakeMod -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Test-PasskeyProvisionerRegistration' {
    BeforeEach {
        Mock -ModuleName PasskeyProvisioner.Core Start-Sleep { }
        Mock -ModuleName PasskeyProvisioner.Core Write-PasskeyProvisionerLog { }
    }

    It 'returns the key when it is found immediately' {
        Mock -ModuleName PasskeyProvisioner.Core Get-PasskeyProvisionerUserKey { @([pscustomobject]@{ Id = 'k1'; DisplayName = 'FIDO SECURITY KEY A' }) }
        (Test-PasskeyProvisionerRegistration -Upn 'u@x.de' -DisplayName 'FIDO SECURITY KEY A' -Config (Get-TestConfig)).Id | Should -BeExactly 'k1'
        Should -Invoke -ModuleName PasskeyProvisioner.Core Start-Sleep -Times 0 -Exactly
    }
    It 'retries until Graph returns the new key' {
        $script:calls = 0
        Mock -ModuleName PasskeyProvisioner.Core Get-PasskeyProvisionerUserKey {
            $script:calls++
            if ($script:calls -lt 3) { @() } else { @([pscustomobject]@{ Id = 'k2'; DisplayName = 'N' }) }
        }
        (Test-PasskeyProvisionerRegistration -Upn 'u@x.de' -DisplayName 'N' -Config (Get-TestConfig)).Id | Should -BeExactly 'k2'
        Should -Invoke -ModuleName PasskeyProvisioner.Core Start-Sleep -Times 2 -Exactly
    }
    It 'throws after the last retry when the key never appears' {
        Mock -ModuleName PasskeyProvisioner.Core Get-PasskeyProvisionerUserKey { @([pscustomobject]@{ Id = 'x'; DisplayName = 'other' }) }
        { Test-PasskeyProvisionerRegistration -Upn 'u@x.de' -DisplayName 'N' -Config (Get-TestConfig) } | Should -Throw '*Verification failed*'
        Should -Invoke -ModuleName PasskeyProvisioner.Core Get-PasskeyProvisionerUserKey -Times 3 -Exactly
    }
}

Describe 'Register-PasskeyProvisionerPasskey' {
    BeforeEach {
        Mock -ModuleName PasskeyProvisioner.Core Write-PasskeyProvisionerLog { }
        Mock -ModuleName PasskeyProvisioner.Core Start-Sleep { }
        $script:cfg = Get-TestConfig
    }

    It 'does not register again when the display name already exists' {
        Mock -ModuleName PasskeyProvisioner.Core Get-PasskeyProvisionerUserKey { @([pscustomobject]@{ Id = 'k1'; DisplayName = 'FIDO SECURITY KEY TEST KEY' }) }
        Mock -ModuleName PasskeyProvisioner.Core New-PasskeyProvisionerPasskeyRegistration { throw 'must not be called' }
        $r = Register-PasskeyProvisionerPasskey -Upn 'u@x.de' -SerialId 'TEST KEY' -Config $script:cfg
        $r.Status | Should -BeExactly 'AlreadyRegistered'
        $r.GraphId | Should -BeExactly 'k1'
        Should -Invoke -ModuleName PasskeyProvisioner.Core New-PasskeyProvisionerPasskeyRegistration -Times 0 -Exactly
    }
    It 'does not register again when the key exists under the legacy name' {
        Mock -ModuleName PasskeyProvisioner.Core Get-PasskeyProvisionerUserKey { @([pscustomobject]@{ Id = 'k7'; DisplayName = 'T2F2-TypeC TEST KEY' }) }
        Mock -ModuleName PasskeyProvisioner.Core New-PasskeyProvisionerPasskeyRegistration { throw 'must not be called' }
        $r = Register-PasskeyProvisionerPasskey -Upn 'u@x.de' -SerialId 'TEST KEY' -Config $script:cfg
        $r.Status | Should -BeExactly 'AlreadyRegistered'
        $r.DisplayName | Should -BeExactly 'T2F2-TypeC TEST KEY'
        $r.GraphId | Should -BeExactly 'k7'
        Should -Invoke -ModuleName PasskeyProvisioner.Core New-PasskeyProvisionerPasskeyRegistration -Times 0 -Exactly
        Should -Invoke -ModuleName PasskeyProvisioner.Core Write-PasskeyProvisionerLog -ParameterFilter { $Message -like '*legacy name*' }
    }
    It 'registers and verifies when the key is new, using the current prefix and the configured API version' {
        $script:n = 0
        Mock -ModuleName PasskeyProvisioner.Core Get-PasskeyProvisionerUserKey {
            $script:n++
            if ($script:n -eq 1) { @() } else { @([pscustomobject]@{ Id = 'k9'; DisplayName = 'FIDO SECURITY KEY TEST KEY' }) }
        }
        Mock -ModuleName PasskeyProvisioner.Core New-PasskeyProvisionerPasskeyRegistration { [pscustomobject]@{ id = 'k9'; displayName = $DisplayName } }
        $r = Register-PasskeyProvisionerPasskey -Upn 'u@x.de' -SerialId 'TEST KEY' -Config (Get-TestConfig 'v1.0')
        $r.Status | Should -BeExactly 'Registered'
        $r.GraphId | Should -BeExactly 'k9'
        Should -Invoke -ModuleName PasskeyProvisioner.Core New-PasskeyProvisionerPasskeyRegistration -Times 1 -Exactly -ParameterFilter {
            $DisplayName -eq 'FIDO SECURITY KEY TEST KEY' -and $ApiVersion -eq 'v1.0'
        }
    }
    It 'does not touch the key or post anything with -WhatIf' {
        Mock -ModuleName PasskeyProvisioner.Core Get-PasskeyProvisionerUserKey { @() }
        Mock -ModuleName PasskeyProvisioner.Core New-PasskeyProvisionerPasskeyRegistration { throw 'must not be called' }
        $r = Register-PasskeyProvisionerPasskey -Upn 'u@x.de' -SerialId 'TEST KEY' -Config $script:cfg -WhatIf
        $r.Status | Should -BeExactly 'WhatIf'
        Should -Invoke -ModuleName PasskeyProvisioner.Core New-PasskeyProvisionerPasskeyRegistration -Times 0 -Exactly
    }
    It 'never registers when the lookup itself fails' {
        Mock -ModuleName PasskeyProvisioner.Core Get-PasskeyProvisionerUserKey { throw 'Graph unavailable' }
        Mock -ModuleName PasskeyProvisioner.Core New-PasskeyProvisionerPasskeyRegistration { throw 'must not be called' }
        { Register-PasskeyProvisionerPasskey -Upn 'u@x.de' -SerialId 'TEST KEY' -Config $script:cfg } | Should -Throw '*Graph unavailable*'
        Should -Invoke -ModuleName PasskeyProvisioner.Core New-PasskeyProvisionerPasskeyRegistration -Times 0 -Exactly
    }
}

Describe 'Write-PasskeyProvisionerLog' {
    AfterEach {
        Set-PasskeyProvisionerLogSink
        Stop-PasskeyProvisionerLogFile
    }

    It 'sends level and a formatted ASCII line to the registered sink' {
        $script:got = $null
        Set-PasskeyProvisionerLogSink -Sink { param($m, $l, $line) $script:got = [pscustomobject]@{ M = $m; L = $l; Line = $line } }
        Write-PasskeyProvisionerLog 'hello' 'Warning'
        $script:got.M | Should -BeExactly 'hello'
        $script:got.L | Should -BeExactly 'Warning'
        $script:got.Line | Should -Match '^\[\d{2}:\d{2}:\d{2}\] \[!!\]  hello$'
    }
}

Describe 'Log file' {
    BeforeAll {
        $script:Tmp = Join-Path ([IO.Path]::GetTempPath()) ("passkeyprovisioner-log-" + [guid]::NewGuid().ToString('N'))
    }
    AfterAll { Remove-Item $script:Tmp -Recurse -Force -ErrorAction SilentlyContinue }
    AfterEach {
        Set-PasskeyProvisionerLogSink
        Stop-PasskeyProvisionerLogFile
    }

    It 'creates the directory and a timestamped file, and appends every entry' {
        Set-PasskeyProvisionerLogSink -Sink { }
        $path = Start-PasskeyProvisionerLogFile -Directory $script:Tmp
        $path | Should -Match '\\\d{8}-\d{6}\.log$'
        Test-Path $path | Should -BeTrue
        Write-PasskeyProvisionerLog 'first' 'Info'
        Write-PasskeyProvisionerLog 'second' 'Error'
        $lines = @(Get-Content $path)
        $lines.Count | Should -Be 2
        $lines[0] | Should -Match '\[>>\]  first$'
        $lines[1] | Should -Match '\[ERR\] second$'
    }
    It 'stops writing after Stop-PasskeyProvisionerLogFile' {
        Set-PasskeyProvisionerLogSink -Sink { }
        $path = Start-PasskeyProvisionerLogFile -Directory $script:Tmp
        Write-PasskeyProvisionerLog 'kept' 'Info'
        Stop-PasskeyProvisionerLogFile
        Write-PasskeyProvisionerLog 'dropped' 'Info'
        @(Get-Content $path).Count | Should -Be 1
    }
    It 'gives two files started in the same second different names' {
        $a = Start-PasskeyProvisionerLogFile -Directory $script:Tmp
        $b = Start-PasskeyProvisionerLogFile -Directory $script:Tmp
        $a | Should -Not -Be $b
    }
    It 'still writes log lines during a -WhatIf registration (no WhatIf leak into the writer)' {
        Set-PasskeyProvisionerLogSink -Sink { }
        $path = Start-PasskeyProvisionerLogFile -Directory $script:Tmp
        Mock -ModuleName PasskeyProvisioner.Core Get-PasskeyProvisionerUserKey { @() }
        Register-PasskeyProvisionerPasskey -Upn 'u@x.de' -SerialId 'S1' -Config (Get-TestConfig) -WhatIf | Out-Null
        (Get-Content $path -Raw) | Should -Match 'Checking existing registrations'
    }
}

Describe 'Remove-PasskeyProvisionerUserKey' {
    BeforeEach {
        Mock -ModuleName PasskeyProvisioner.Core Write-PasskeyProvisionerLog { }
        Mock -ModuleName PasskeyProvisioner.Core Remove-MgUserAuthenticationFido2Method { }
        Mock -ModuleName PasskeyProvisioner.Core Remove-MgBetaUserAuthenticationFido2Method { }
    }

    It 'deletes through the v1.0 cmdlet with the user and key id' {
        Remove-PasskeyProvisionerUserKey -Upn 'u@x.de' -KeyId 'k1' -DisplayName 'FIDO SECURITY KEY 1' -Config (Get-TestConfig 'v1.0') -Confirm:$false
        Should -Invoke -ModuleName PasskeyProvisioner.Core Remove-MgUserAuthenticationFido2Method -Times 1 -Exactly -ParameterFilter { $UserId -eq 'u@x.de' -and $Fido2AuthenticationMethodId -eq 'k1' }
        Should -Invoke -ModuleName PasskeyProvisioner.Core Remove-MgBetaUserAuthenticationFido2Method -Times 0 -Exactly
        Should -Invoke -ModuleName PasskeyProvisioner.Core Write-PasskeyProvisionerLog -ParameterFilter { $Message -like 'Deleted passkey registration*' -and $Level -eq 'Success' }
    }
    It 'deletes through the beta cmdlet when the API version is beta' {
        Remove-PasskeyProvisionerUserKey -Upn 'u@x.de' -KeyId 'k2' -Config (Get-TestConfig 'beta') -Confirm:$false
        Should -Invoke -ModuleName PasskeyProvisioner.Core Remove-MgBetaUserAuthenticationFido2Method -Times 1 -Exactly -ParameterFilter { $Fido2AuthenticationMethodId -eq 'k2' }
        Should -Invoke -ModuleName PasskeyProvisioner.Core Remove-MgUserAuthenticationFido2Method -Times 0 -Exactly
    }
    It 'deletes nothing with -WhatIf' {
        Remove-PasskeyProvisionerUserKey -Upn 'u@x.de' -KeyId 'k3' -Config (Get-TestConfig 'v1.0') -WhatIf
        Should -Invoke -ModuleName PasskeyProvisioner.Core Remove-MgUserAuthenticationFido2Method -Times 0 -Exactly
    }
    It 'logs the role hint and rethrows when Graph denies access' {
        Mock -ModuleName PasskeyProvisioner.Core Remove-MgUserAuthenticationFido2Method { throw 'accessDenied: Request Authorization failed' }
        { Remove-PasskeyProvisionerUserKey -Upn 'u@x.de' -KeyId 'k4' -Config (Get-TestConfig 'v1.0') -Confirm:$false } | Should -Throw '*Authorization failed*'
        Should -Invoke -ModuleName PasskeyProvisioner.Core Write-PasskeyProvisionerLog -ParameterFilter { $Message -like 'Hint:*' }
    }
}

Describe 'Get-PasskeyProvisionerResetCountdown' {
    BeforeAll { $script:t0 = [datetime]'2026-10-26T12:00:00' }

    It 'counts down from ten seconds' {
        $c = Get-PasskeyProvisionerResetCountdown -InsertedAt $script:t0 -Now $script:t0
        $c.RemainingSeconds | Should -Be 10
        $c.Fraction | Should -Be 0
        $c.Expired | Should -BeFalse
    }
    It 'reports the time left in the middle of the window' {
        $c = Get-PasskeyProvisionerResetCountdown -InsertedAt $script:t0 -Now $script:t0.AddSeconds(4)
        $c.RemainingSeconds | Should -Be 6
        $c.Fraction | Should -Be 0.4
        $c.Expired | Should -BeFalse
    }
    It 'is expired from ten seconds on and never goes negative' {
        (Get-PasskeyProvisionerResetCountdown -InsertedAt $script:t0 -Now $script:t0.AddSeconds(10)).Expired | Should -BeTrue
        $late = Get-PasskeyProvisionerResetCountdown -InsertedAt $script:t0 -Now $script:t0.AddSeconds(60)
        $late.RemainingSeconds | Should -Be 0
        $late.Fraction | Should -Be 1
    }
    It 'accepts another window length' {
        (Get-PasskeyProvisionerResetCountdown -InsertedAt $script:t0 -Now $script:t0.AddSeconds(6) -WindowSeconds 5).Expired | Should -BeTrue
    }
}