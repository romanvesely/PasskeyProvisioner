# Changelog

All notable changes are documented here. Format based on [Keep a Changelog](https://keepachangelog.com/).
Live test results for changes that touch the enrollment path are recorded under the respective entry.

## [1.0.0] - 2026-10-27

First release.

### Registration
- Register FIDO2 security keys (Token2 T2F2) in Microsoft Entra ID on behalf of users: a single user, or a CSV file with the
  columns `UPN,SerialID`. Runs as a standard user; the Microsoft sign-in opens interactively.
- The Microsoft Graph request is built by hand (`id` as Base64Url without padding) and posted to
  `/users/{upn}/authentication/fido2Methods`; Graph v1.0 by default, `beta` as an explicit fallback (`graphApiVersion`).
  Verified live: HTTP 201 Created.
- Display name `<prefix> <serial>` (default prefix `FIDO SECURITY KEY`). The duplicate check also recognizes older prefixes
  (`legacyDisplayNamePrefixes`, default `T2F2-TypeC`) and skips a key that is already registered.
- The registration is verified afterwards, with retries for the replication delay of Entra.
- Bulk runs: one row per user with a status, failures do not stop the run, a result file is written after every row
  (`users.result.csv`), `-Resume` skips users that were already registered. A different physical key is required for every row
  (key swap gate).
- Clear hints for common Graph errors (for example HTTP 403: activate the Authentication Administrator role in PIM).

### Keys
- Key detection, a list of all HID devices to identify an unknown key, and a lookup of the passkeys registered for a user.
- Remove an old Entra registration of a key (found by user and serial, current and legacy names).
- Reset and PIN through the Windows security key dialog (no administrator rights needed): the dialog opens centered over the
  window, the large Settings window is never visible, and everything is cleaned up afterwards. A countdown shows the 10 second
  window after the key was inserted for a reset.

### Application
- WPF window in two themes, Rose Pine (dark) and Rose Pine Dawn (light), with System / Light / Dark modes (default System, follows
  Windows). Keyboard navigation (Ctrl+1/2/3, Ctrl+T), activity log with filters and a log file per run
  (`%LOCALAPPDATA%\PasskeyProvisioner\logs`).
- The tenant is not built in: the app remembers the tenant of the last successful sign-in; `tenantId` in `settings.json` overrides it.
- Pop-up windows (sign-in, key dialog) are centered on the screen.
- A bongo cat on the tenant chip taps along with the keyboard.
- `PasskeyProvisioner.exe`: a single file (ps2exe), no console window, unpacks itself on first start. A hidden console window gives
  the Microsoft sign-in the window handle it needs (see `spikes/README.md`). The pinned PowerShell modules (Microsoft Graph 2.39.0,
  DSInternals.Passkeys 3.2.0) are installed once on first use.
- Headless runner `src/Invoke-PasskeyProvisioner.ps1` with `-WhatIf` and `-Resume`.

### Quality
- Licensed under GPL-3.0.
- Pester tests for the core module and the theme maths, an end to end UI test in simulation mode (also against the EXE), a test
  against the real Windows key dialog, PSScriptAnalyzer clean.
