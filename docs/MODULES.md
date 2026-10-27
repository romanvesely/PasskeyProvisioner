# PowerShell module matrix

## Pinned versions

| Module | Version | Source of truth |
|---|---|---|
| Microsoft.Graph.Authentication | 2.39.0 | `config/settings.sample.json` |
| Microsoft.Graph.Beta.Identity.SignIns | 2.39.0 | `config/settings.sample.json`, only with the fallback `graphApiVersion: beta` |
| Microsoft.Graph.Identity.SignIns | 2.39.0 | `config/settings.sample.json`, default (`graphApiVersion: v1.0`); always loaded transitively by DSInternals.Passkeys |
| DSInternals.Passkeys | 3.2.0 | `config/settings.sample.json` |

Latest on the PowerShell Gallery (checked 2026-10-26): Graph 2.41.2, DSInternals.Passkeys 3.4.0. No upgrade is planned.

## Which modules are installed and imported

The configuration property `activeModules` is derived from `graphApiVersion`: Microsoft.Graph.Authentication and
DSInternals.Passkeys always, plus Microsoft.Graph.Beta.Identity.SignIns for `beta` or Microsoft.Graph.Identity.SignIns
for `v1.0`. Pins for modules that are not active are ignored.

## Rules

1. One process, one module version. .NET cannot replace an already loaded assembly.
2. All Graph modules must share the same version as `Microsoft.Graph.Authentication`.
3. Windows PowerShell 5.1 and PowerShell 7 have separate module paths:
   `Documents\WindowsPowerShell\Modules` (5.1, used at runtime) and `Documents\PowerShell\Modules` (7, only for ps2exe).

## Symptoms and repair

| Symptom | Cause | Fix |
|---|---|---|
| `Assembly with same name is already loaded` | Different module version already loaded in this session | Close the window, start a new PowerShell process |
| Import hangs | Same as above | Same as above |
| HTTP 400 `publicKeyCredential.id cannot be empty` | `New-Passkey -DisplayName` or pipeline binding on DSInternals.Passkeys 3.x | Build the Graph body manually, see `PasskeyProvisioner.Core.psm1` |
| Cmdlet not found after upgrade | Cmdlets were renamed in DSInternals.Passkeys 3.1 | Check `Get-Command -Module DSInternals.Passkeys` |
| Several versions installed | Unpinned `Install-Module` runs | `Uninstall-Module -Name <name> -RequiredVersion <old>` for each stale version |

## Inspecting what is installed

```powershell
Get-Module -ListAvailable Microsoft.Graph*, DSInternals.Passkeys | Sort-Object Name, Version | Select-Object Name, Version, Path
```
