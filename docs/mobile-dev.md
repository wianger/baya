# Baya Android Development

The Android client lives in `app/`. iOS was intentionally excluded from this
standalone repository; the current release target is Android only.

## Repositories

- Baya host and client: <https://github.com/wianger/baya>
- Development branch: `codex/baya-standalone-20261101`

The old `wianger/remote_pi` repository and its `main` branch are not build or
release dependencies.

## Android compatibility

The launcher name is **Baya**, while the Android application ID remains:

```text
dev.wianger.remotepi
```

Changing the application ID would create a second app and lose the existing
pairings and local session cache. The existing signing key must likewise remain
unchanged:

```text
SHA-256 bdaba7b38a226cf6bcf2673d24a8f56453ffdce66f3b3402e48e0bca7b884eaa
```

The private key lives outside the checkout under
`%LOCALAPPDATA%\RemotePiMobileBuild\signing`. That legacy folder name is kept
deliberately so builds continue to use the installed app's signing identity.

## Build

```powershell
$env:HTTPS_PROXY = 'http://127.0.0.1:7897'
.\scripts\build-mobile-windows.ps1
```

The default output is:

```text
%USERPROFILE%\Downloads\Baya-Android.apk
```

The script snapshots the source to a separate build directory, verifies the
Flutter, JDK, SDK, and signing tools, builds the ARM64 release APK, and
verifies the signature. It does not write key material into the checkout.

## Verify an APK

```powershell
$tools = 'C:\Scoop\persist\android-clt\build-tools\36.0.0'
$apk = "$env:USERPROFILE\Downloads\Baya-Android.apk"
& "$tools\aapt2.exe" dump badging $apk
& "$tools\apksigner.bat" verify --print-certs $apk
```

Expected package/version example:

```text
package: name='dev.wianger.remotepi' versionCode='62' versionName='1.2.52'
```

The exact version changes with each release; the package ID and certificate
must remain stable.

## Publish

Commit and push the exact development branch first, keep the checkout clean,
then run:

```powershell
.\scripts\publish-android-dev-windows.ps1 `
  -Apk "$env:USERPROFILE\Downloads\Baya-Android.apk" `
  -NotesFile "$env:TEMP\baya-release-notes.md" `
  -Publish
```

Releases use:

```text
tag:    android-dev-v<version>+<versionCode>
asset:  Baya-Android.apk
repo:   wianger/baya
```

The in-app updater reads only signed assets attached to this repository. Draft
releases are ignored, and every build number must be higher than every
previously published Android development release.

## Tests

```powershell
cd app
flutter pub get
flutter analyze
flutter test
```

For deterministic layout previews:

```powershell
.\scripts\preview-mobile-windows.ps1 -Theme dark
```

Preview images are written to
`%USERPROFILE%\Downloads\RemotePi-UI-Preview` for compatibility with existing
local preview scripts. That path may be changed with `-OutputDirectory`.
