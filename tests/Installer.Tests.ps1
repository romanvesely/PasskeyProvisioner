BeforeAll {
    # Fill the installer template with fake content and run it against TestDrive, never against Program Files.
    $template = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\packaging\Install-PasskeyProvisioner.template.ps1'))
    $script:ExeBytes = [byte[]](1..200 | ForEach-Object { $_ % 256 })
    $script:Settings = '{ "tenantId": "contoso.onmicrosoft.com" }'
    function Write-TestInstaller([string]$SettingsText) {
        $settingsBase64 = if ($SettingsText) { [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($SettingsText)) } else { '' }
        $text = $template.Replace('@@VERSION@@', '9.9.9.0').Replace('@@TARGETDIR@@', 'C:\never\used').
            Replace('@@SETTINGS@@', $settingsBase64).Replace('@@EXE@@', [Convert]::ToBase64String($script:ExeBytes))
        $path = Join-Path $TestDrive 'Install-PasskeyProvisioner.ps1'
        [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.ASCIIEncoding))
        $path
    }
    function Invoke-TestInstaller([string]$Path, [switch]$Uninstall) {
        $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Path, '-TargetDir', $script:Target,
            '-ShortcutDir', $script:Shortcuts, '-LogPath', $script:Log)
        if ($Uninstall) { $arguments += '-Uninstall' }
        $null = & powershell.exe @arguments
        $LASTEXITCODE
    }
}

Describe 'Install-PasskeyProvisioner' {
    BeforeEach {
        $script:Target = Join-Path $TestDrive 'Company\PasskeyProvisioner'
        $script:Shortcuts = Join-Path $TestDrive 'StartMenu'
        $script:Log = Join-Path $TestDrive 'logs\install.log'
        Remove-Item -LiteralPath (Join-Path $TestDrive 'Company'), $script:Shortcuts -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'contains only ASCII' {
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $PSScriptRoot '..\packaging\Install-PasskeyProvisioner.template.ps1'))
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }

    It 'installs the EXE, settings.json and the start menu shortcut' {
        $installer = Write-TestInstaller $script:Settings
        Invoke-TestInstaller $installer | Should -Be 0
        [System.IO.File]::ReadAllBytes((Join-Path $script:Target 'PasskeyProvisioner.exe')) | Should -Be $script:ExeBytes
        Get-Content -LiteralPath (Join-Path $script:Target 'settings.json') -Raw | Should -Be $script:Settings
        Join-Path $script:Shortcuts 'Passkey Provisioner.lnk' | Should -Exist
        Get-Content -LiteralPath $script:Log -Raw | Should -Match 'Installed'
    }

    It 'replaces an older installation completely' {
        [void][System.IO.Directory]::CreateDirectory($script:Target)
        Set-Content -LiteralPath (Join-Path $script:Target 'leftover.txt') -Value 'old'
        Invoke-TestInstaller (Write-TestInstaller '') | Should -Be 0
        Join-Path $script:Target 'leftover.txt' | Should -Not -Exist
        Join-Path $script:Target 'settings.json' | Should -Not -Exist
        Join-Path $script:Target 'PasskeyProvisioner.exe' | Should -Exist
    }

    It 'uninstalls and removes the empty company folder' {
        $installer = Write-TestInstaller $script:Settings
        Invoke-TestInstaller $installer | Should -Be 0
        Invoke-TestInstaller $installer -Uninstall | Should -Be 0
        $script:Target | Should -Not -Exist
        Join-Path $TestDrive 'Company' | Should -Not -Exist
        Join-Path $script:Shortcuts 'Passkey Provisioner.lnk' | Should -Not -Exist
    }

    It 'keeps the company folder when it holds other applications' {
        $installer = Write-TestInstaller ''
        [void][System.IO.Directory]::CreateDirectory((Join-Path $TestDrive 'Company\OtherApp'))
        Invoke-TestInstaller $installer | Should -Be 0
        Invoke-TestInstaller $installer -Uninstall | Should -Be 0
        Join-Path $TestDrive 'Company\OtherApp' | Should -Exist
    }
}
