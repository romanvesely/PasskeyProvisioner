# Live test checklist

Required for every change that touches the enrollment path (module pins, Graph body, Graph API version, duplicate
check, verification). Tests need a real FIDO2 key and a dedicated test user. They are run by the project owner.

## Prerequisites

- Test user UPN: `test.user@contoso.com`
- Test key serial: `TEST KEY` (display name in Entra becomes `FIDO SECURITY KEY TEST KEY`)
- Tenant: `contoso.onmicrosoft.com`
- The key must not already be registered for the test user. Factory reset the key if needed (10 s window after insertion).
- Run as a standard user in a fresh Windows PowerShell 5.1 process

## Steps

1. Start the tool (GUI or headless runner) in a fresh Windows PowerShell 5.1 process and connect to the tenant.
   Headless: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\Invoke-PasskeyProvisioner.ps1 -Upn test.user@contoso.com -SerialId "TEST KEY"`
   Dry run first (reads Graph, does not touch the key): add `-WhatIf`.
2. Register the key for the test user.
3. Expected log lines: Graph response with HTTP 201, `Graph response displayName: '<prefix> <serial>'`,
   `Passkey registered successfully for user <upn>.`
4. Run the registration again for the same user and serial. Expected: `Passkey already registered ... Verifying...`,
   no second POST.
5. Bulk: a CSV with two rows, one key swapped between rows. Expected: one result row per user, failures do not abort.

## Clean up

Delete the test registration so the key can be reused:

```powershell
Connect-MgGraph -Scopes 'UserAuthenticationMethod.ReadWrite.All' -TenantId <tenant>
Get-MgBetaUserAuthenticationFido2Method -UserId <upn>
Remove-MgBetaUserAuthenticationFido2Method -UserId <upn> -Fido2AuthenticationMethodId <id>
```

## Record the result

Add a line to the CHANGELOG entry of the change: date, commit, tested combination, Graph status, log excerpt.

## Phase 2 additions

Prerequisite: activate the Authentication Administrator role in PIM first. Without it Graph answers HTTP 403 and the
tool logs a hint.

### A. Graph API version v1.0

1. v1.0 is the default since Phase 2. For the fallback test create `config/settings.json` (untracked) with
   `{ "graphApiVersion": "beta" }`.
2. Run the registration for the test user (steps 1-3 above). The first start installs/imports
   `Microsoft.Graph.Identity.SignIns` instead of the beta module; the log shows the module names.
3. Expected: Graph response with the display name and an id, then `Passkey registered successfully`.
4. Remove the test registration, then repeat once with `"graphApiVersion": "beta"` (or delete the file) to confirm the
   fallback still works.

### B. Log file and result file (bulk with resume)

1. Copy `samples/users.sample.csv` to `samples/users-test.csv` (ignored by git) and put the test user and `TEST KEY` in it.
2. Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\Invoke-PasskeyProvisioner.ps1 -CsvPath .\samples\users-test.csv`
3. Expected: `samples\users-test.result.csv` with Status Registered and a GraphId; a log file in
   `%LOCALAPPDATA%\PasskeyProvisioner\logs` whose content matches the console.
4. Run the same command again with `-Resume`. Expected: `Skipped: already done in an earlier run (-Resume).`, no touch
   dialog, result file unchanged.
5. Delete the test registration afterwards.

### C. Legacy display name (optional)

Rename an existing test registration in the portal to `T2F2-TypeC TEST KEY` (or register with the legacy tool),
run the registration again. Expected: `Key is already registered under the legacy name`, status AlreadyRegistered,
no new registration.

## Phase 3 additions (GUI)

Prerequisite: Authentication Administrator role active in PIM, test key factory reset, start the app with
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\PasskeyProvisioner.App\Start-PasskeyProvisionerApp.ps1`.
The automated checks (`tests/Invoke-UiSimulationTest.ps1`) already cover the logic with fakes; this test covers what
only real hardware and a real tenant can show.

1. **Start and key detection.** Window opens without freezing. With the key plugged in the top bar shows "Key detected" and the
   Keys view shows the device with VID and PID (expected for the Token2 key: VID 096E, PID 0858). Pull the key: it turns to "No key" within a few seconds.
2. **Connect (step 1).** Click Connect. The window stays responsive while modules load and the browser sign-in is open;
   the detail text next to the button shows the progress. After sign-in the chip shows your account.
3. **Single user (steps 2 and 3).** Choose "Single user", enter `test.user@contoso.com` and `TEST KEY`,
   Review, Start. Expected: banner "Touch the key", the Windows security key dialog appears (it may open behind the app
   window - note this), touch the key, row turns to Registered, results page shows 1 registered.
   If the Windows dialog does not appear when started from the background runspace, report it: the fallback is to run
   the touch step on the window thread.
4. **Already registered.** Run the same user and serial again. Expected: "Already registered", no touch prompt and no
   key needed.
5. **Cancel.** Start a CSV with two rows (two different users, same test key is fine) and press Cancel while the app
   waits for the key. Expected: stops after the current user, remaining rows stay Pending.
6. **Lookup.** Keys view, look up the test user: the registered passkey is listed. Then clean up the test registration.

## Phase 4 additions (reset, PIN, Entra cleanup)

Prerequisite: a key that may be erased (the test key), Authentication Administrator role active in PIM, the test key
registered for `test.user@contoso.com` as `TEST KEY`. Run as a standard user.

1. **Reset.** Keys view, *Reset key...*. Read the warning, click *Open key management*. Only the small Windows dialog
   ("Windows Hello setup") appears, centered over the tool; the large Settings window stays hidden. In the dialog choose
   Manage and then Reset. Follow Windows: remove the key, insert it again, touch it. Watch the countdown in the tool:
   it should start within about a second of inserting the key and count down from 10 seconds.
   Note whether the dialog is in front of the tool and whether the reset succeeded within the window. Close the dialog
   with its X once: the tool must not leave a Settings window in the taskbar. Automated check of this behavior:
   `tests/Invoke-RealDialogTest.ps1` (opens the real dialog, changes nothing).
2. **Done.** Click *Done*. Expected: log line "Reset started via Windows Settings", status bar reminder about Entra.
3. **Entra cleanup.** Connect first (Register, step 1). Keys view, *Remove an Entra registration*: UPN
   `test.user@contoso.com`, serial `TEST KEY`, *Find*. Expected: the old registration is listed.
   *Delete registration...*, confirm. Expected: "1 registration(s) deleted" and the entry disappears from the portal
   under Security info.
4. **Register again.** Register the reset key for the test user (Register view). Expected: Registered.
5. **PIN.** *Set or change PIN...*, follow the Windows dialog, set a PIN. Then register again once (Windows may now ask for
   the PIN during registration).
6. **Detection while the key is pulled.** Pull the key during the countdown: the countdown disappears, and it restarts when
   the key is inserted.
## Pop-up placement (sign-in window)

1. Start the tool and click *Connect* (Register, step 1). If Windows shows a sign-in window, note where it appears: it should
   open centered on the screen.
2. After connecting, open *Log* and copy every line that starts with "Window opened during sign-in". Each line names the
   process, window class, title and owner of a window that appeared while connecting. If the sign-in window was not centered,
   these lines tell which window it was, so the detection can be extended. A line "Centered this window on the screen" means
   the tool moved it.
3. With single sign-on the sign-in is silent and no window appears; then there is nothing to check.
4. Optional: set `"centerPopupWindows": false` in `config/settings.json` to switch the centering off.

## EXE (Phase 6)

Run with `dist\PasskeyProvisioner.exe` as a standard user, ideally also on a second PC that has never seen the tool.

1. Double-click: the window opens, no terminal window is visible. Before the first start, the app is unpacked to
   `%LOCALAPPDATA%\PasskeyProvisioner\app\<hash>` (a few seconds).
2. Connect: the Microsoft sign-in window appears and the connection succeeds. The log shows `Window opened during sign-in`.
   On a PC where Windows Terminal is the default terminal app, check that no terminal window flashes up.
3. Register the test key (see steps above). Reset and PIN: the Windows dialog opens centered, the large Settings window is
   never visible and nothing stays open afterwards.
4. Close and start again: the second start is fast (no unpacking, no module installation).
5. Record the result in the CHANGELOG.
