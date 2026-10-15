# Signing, notarisation and auto-update: the switch

Today the app ships **ad-hoc signed** on macOS, because there is no paid Developer ID. This
document is the checklist for turning real signing on later. No code changes are needed; it is
a certificate, a few secrets and two lines in the packaging script.

## Current state (no certificate)

`scripts/package-mac.sh` runs, after `flutter build macos --release` and after copying ffmpeg
into `Contents/Resources/ffmpeg/`:

```
codesign --force --deep --sign "-" --entitlements macos/Runner/Release.entitlements --timestamp=none Soundbites.app
codesign --verify --deep --strict --verbose=2 Soundbites.app
```

`-` is the ad-hoc identity: a signature with no Team ID. The identity comes from the
`SIGNING_IDENTITY` environment variable when set, so the switch below needs no script edit.

The entitlements (`macos/Runner/Release.entitlements` and `DebugProfile.entitlements`) turn the
App Sandbox **off** (the app spawns yt-dlp and ffmpeg and reads any folder the user picks) and
allow JIT and unsigned libraries (`com.apple.security.cs.allow-jit`,
`com.apple.security.cs.disable-library-validation`), which the Flutter engine and the
media playback library need while there is no Team ID.

Why ad-hoc and not nothing: Apple Silicon refuses to run code with no signature at all, and a
bundle modified after signing shows "is damaged and can't be opened" with no approval button.
That is why ffmpeg is copied in **before** signing and why the seal covers the whole bundle
(`--deep`). The build workflow fails if `codesign --verify` rejects the result.

Friends open the app via System Settings > Privacy & Security > Open Anyway
(see `docs/first-time-opening.md`).

## Turning on Developer ID signing and notarisation

1. Enrol in the Apple Developer Program and create a "Developer ID Application" certificate.
   Export it as a `.p12` with a password.
2. In the GitHub repository, add secrets:
   - `MAC_CERT_P12`: the `.p12` file, base64-encoded
   - `MAC_CERT_PASSWORD`: its password
   - `APPLE_API_KEY`, `APPLE_API_KEY_ID`, `APPLE_API_ISSUER`: an App Store Connect API key
     for `notarytool`
3. In `.github/workflows/build.yml`, before the packaging step on the Mac job, import the
   certificate into a temporary keychain (the usual `security create-keychain` /
   `security import` steps) and set `SIGNING_IDENTITY` to the certificate's name
   ("Developer ID Application: Name (TEAMID)").
4. In `scripts/package-mac.sh`, replace `--timestamp=none` with `--timestamp` and add
   `--options runtime` (the hardened runtime, required for notarisation). Remove
   `com.apple.security.cs.disable-library-validation` from both entitlement files (a real Team
   ID makes library validation pass). Keep `allow-jit` and keep the sandbox off.
5. After the `.dmg` is made, notarise and staple:
   ```
   xcrun notarytool submit dist/Soundbites-*.dmg --key "$APPLE_API_KEY" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER" --wait
   xcrun stapler staple dist/Soundbites-*.dmg
   ```
6. Build. The verify step should now print a `TeamIdentifier` rather than `Signature=adhoc`.

## Windows Authenticode

Not planned (SmartScreen warnings are documented instead). If a certificate is ever bought,
sign `build\windows\x64\runner\Release\soundbites.exe` and the finished installer with
`signtool sign /fd SHA256 /td SHA256 /tr <timestamp url> ...` in
`scripts/package-windows.ps1`, or set `SignTool` in `installer/windows/soundbites.iss`.

## Auto-update

The app only **checks** for a newer release (GitHub Releases of this repository) and shows a
link in About. Installing updates by itself would need a signed, notarised Mac app and an
installer that can replace itself on Windows. Once signing is on, the natural route is: download
the new `.dmg` or installer from the release, verify its checksum, and open it for the user.
The repository is public, so GitHub Releases are readable by every copy of the app without a
token. (If it is ever made private again, the update check and the LGPL source offer both need
a public home for the releases.)
