# Deployment with Intune and Robopack

Passkey Provisioner is distributed as an Intune Win32 app. [Robopack](https://robopack.com) wraps the installer script as a custom
app and uploads it to the tenant. The install folder is fixed, so a path exclusion for the rule that blocks unsigned apps can point
at it (for example `C:\Program Files\<Company>\PasskeyProvisioner\`).

## Build a release

1. Raise `ModuleVersion` in `src\PasskeyProvisioner.Core\PasskeyProvisioner.Core.psd1`. It becomes the file version of the EXE
   (`1.0.1` gives `1.0.1.0`) and the version the detection rule compares against. Update `docs\CHANGELOG.md` and run the tests.
2. `pwsh -NoProfile -File build\Build-Exe.ps1`, then `powershell.exe -NoProfile -File build\Build-Installer.ps1`.
   Output: `dist\installer\<version>\Install-PasskeyProvisioner.ps1`. It embeds the EXE and, when present,
   `packaging\settings.local.json` (tenant). Never publish this file; `dist\` and `packaging\*.local.*` are gitignored.
3. Check the build in simulation: `tests\Invoke-UiSimulationTest.ps1 -ExePath dist\PasskeyProvisioner.exe`.

`packaging\package.local.json` (`{ "targetDir": "C:\\Program Files\\<Company>\\PasskeyProvisioner" }`) sets the install folder.

## New package in Robopack

Robopack cannot replace the file of an existing custom package: every version is a new package.

1. Drag `Install-PasskeyProvisioner.ps1` onto **Custom app**, choose **IntuneWin**.
2. Information:

   | Field | Value |
   |---|---|
   | Name | Passkey Provisioner |
   | Version | the new file version, for example `1.0.1.0` |
   | Install command | `"powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "Install-PasskeyProvisioner.ps1"` |
   | Uninstall command | the same with `-Uninstall` at the end |
   | Context / platform | Machine context, 32-bit and 64-bit |
   | Analyze and test | on |

3. Detection rules: type **File/directory**, path `<install folder>`, file `PasskeyProvisioner.exe`, method **Compare file version**,
   operator **Greater than or equal to**, value **the new version**. The old value would make Intune treat the installed old
   version as current and skip the update.
4. Advanced options: description, developer, restart behavior *Suppress restart*. Return codes stay at the defaults:
   0 success, 1618 retry (the app is running), anything else fails.
5. Robopack does not set a logo for script packages. Upload `PasskeyProvisioner.png` on the app in Intune.
6. In Intune open the new app, **Properties > Relationships > Supersedence**, add the previous version with *Uninstall previous
   version: No* (the installer replaces the folder itself), and assign it like the old one.

## Check on a device

- `<install folder>\PasskeyProvisioner.exe` has the new file version, `settings.json` is next to it.
- `C:\Windows\Logs\Software\PasskeyProvisioner-install.log` shows `Installed ... (file version <new>)`.
- Start the app, connect, register one key with a test user: the log must show `201` (see `LIVE-TEST.md`).
- The log (`%LOCALAPPDATA%\PasskeyProvisioner\logs\`) lists every window opened during sign-in. Defender or AppLocker blocks show up in
  the event logs `Microsoft-Windows-Windows Defender/Operational` (1121, 1122) and `Microsoft-Windows-AppLocker/*` (8003 to 8007).

## Pitfalls

- The EXE is unsigned. Defender may remove it, and the exclusion has to cover the install folder.
- Admin accounts must not be added to the device under *Settings > Accounts > Access work or school*. Otherwise the sign-in fails
  with `AADSTS1400011`.
- The first connect installs the pinned Graph and DSInternals modules per user from the PowerShell Gallery. A user without access to
  the gallery cannot connect.
- Installing as a standard user is not possible. The installer runs as SYSTEM through Intune; the app itself never needs elevation.
