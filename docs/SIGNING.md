# Signing, notarisation and auto-update: the switch

Today the app ships **unsigned by Apple's standards but ad-hoc signed**, because there is no paid
Developer ID. This document is the checklist for turning real signing on later. No code changes
are needed; it is configuration plus one small module.

## Current state (no certificate)

In `electron-builder.yml`:

```yaml
mac:
  identity: "-"            # ad-hoc: a signature with no Team ID
  hardenedRuntime: false   # off; only needed for notarisation
  notarize: false
  entitlements: build/entitlements.mac.plist          # allow-jit + disable-library-validation
  entitlementsInherit: build/entitlements.mac.inherit.plist
```

Why ad-hoc and not nothing: Apple Silicon refuses to run code with no signature at all, and a
bundle modified after signing shows "is damaged and can't be opened" with no approval button.
electron-builder 26.15 does **not** fall back to ad-hoc signing on its own (earlier 26.x did and
it was removed), so `identity: "-"` must stay explicit. The build workflow runs
`codesign --verify --deep --strict` on the finished app and fails if the seal is broken.

Friends open the app via System Settings > Privacy & Security > Open Anyway
(see `docs/first-time-opening.md`).

## Turning on Developer ID signing and notarisation

1. Enrol in the Apple Developer Program and create a "Developer ID Application" certificate.
   Export it as a `.p12` with a password.
2. In the GitHub repository, add secrets:
   - `CSC_LINK`: the `.p12` file, base64-encoded
   - `CSC_KEY_PASSWORD`: its password
   - `APPLE_API_KEY`, `APPLE_API_KEY_ID`, `APPLE_API_ISSUER`: an App Store Connect API key
     (electron-builder's recommended notarisation credentials)
3. In `electron-builder.yml`, change the Mac section to:
   ```yaml
   mac:
     # identity: not set, so electron-builder finds the Developer ID certificate from CSC_LINK
     hardenedRuntime: true
     notarize: true
   ```
   and remove `com.apple.security.cs.disable-library-validation` from both entitlement files
   (a real Team ID makes library validation pass).
4. In `.github/workflows/build.yml`, remove `CSC_IDENTITY_AUTO_DISCOVERY: "false"` from the
   Mac packaging step and pass the five secrets as environment variables.
5. Build. The verify step should now print a `TeamIdentifier` rather than `Signature=adhoc`.

## Windows Authenticode

Not planned (SmartScreen warnings are documented instead). If a certificate is ever bought:
set `win.certificateSubjectName` or `CSC_LINK`/`CSC_KEY_PASSWORD` for Windows in the Windows job,
or configure `win.azureSignOptions` for Azure Trusted Signing.

## Auto-update

Automatic updating needs a signed, notarised Mac app (Squirrel.Mac refuses unsigned updates).
Once the above is done:

1. `npm install electron-updater`
2. In the main process, on launch: `autoUpdater.checkForUpdatesAndNotify()` from
   `electron-updater`, replacing the "a newer version is available" link in the About screen.
   `publish` in `electron-builder.yml` already points at GitHub Releases for this repository.
3. Because the repository is private, friends' copies cannot read GitHub Releases without a
   token. Either make the releases public (a separate public repository that only holds
   releases), or ship a read-only token in the app (not recommended). Decide before enabling.
