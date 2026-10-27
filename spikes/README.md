# Spikes

## Reset and PIN through undocumented webauthn.dll exports (Phase 4, 2026-10-26): not pursued

**Question.** The Windows Settings app resets security keys and sets PINs without administrator rights. `webauthn.dll`
on this machine (Windows 11 25H2) exports `WebAuthNCtapManageSelect`, `WebAuthNCtapManageResetDevice`,
`WebAuthNCtapManageSetPin`, `WebAuthNCtapManageChangePin`, `WebAuthNCtapManageDeleteCredential` and more. Could the tool
call these directly and run the whole reset inside its own window?

**Rules for the spike.** Prototypes only from public sources (Microsoft headers, Chromium, python-fido2, vendor
documentation). No disassembly of Windows binaries and no reverse engineering of `fido2-manage.exe`. Time box: 3 hours.

**Result.** Stopped after the research step; no prototype was written.

- The names are not part of the published `webauthn.h`. Microsoft's reference lists only `WebAuthNAuthenticatorMakeCredential`,
  `WebAuthNAuthenticatorGetAssertion` and the related public functions.
- Third-party export lists (for example the MinGW `webauthn.def`) show the names, but no parameter types or semantics.
- No public project documents their prototypes or confirms that the Settings app uses them.
- Calling a function without knowing its prototype can crash the process or corrupt the key state, and an undocumented
  interface can change with any Windows update.

**Decision.** The tool guides the documented Windows dialog (`ms-settings:signinoptions-launchsecuritykeyenrollment`)
instead: it opens the dialog, shows the steps and the 10 second reset window, and then helps remove the old Entra
registration. Windows does not report the outcome of the dialog back, so the tool never claims success.

**Revisit when** Microsoft publishes the CTAP management functions in `webauthn.h` (the Windows SDK header is the
signal), or a vendor-neutral open source library documents them.
