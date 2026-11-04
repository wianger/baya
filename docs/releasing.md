# Branches, versions and releases

## Branches

- `main` is the only long-lived branch. Everything released comes from it.
- Work that needs review goes on a short-lived branch named
  `<type>/<topic>` (`feat/elicitation`, `fix/startup-notes`), with the same
  types as commits, and is merged into `main`.
- Dependabot's branches (`dependabot/…`) are its own.

## Commits

[Conventional Commits](https://www.conventionalcommits.org):
`<type>(<scope>): <summary>`.

- Types: `feat`, `fix`, `perf`, `refactor`, `docs`, `test`, `build`, `ci`,
  `chore`. A breaking change adds `!` (`feat(host)!: …`).
- Scopes: `app`, `host`, or none for both. The summary says what changed for
  the user, in the present tense.

## Versions

The app and the host are versioned separately, with
[Semantic Versioning](https://semver.org).

- **App**: `version: <x.y.z>+<build>` in `app/pubspec.yaml`. The build number
  is Android's `versionCode` and goes up by one with every release.
- **Host**: `version` in `host/package.json`.

The phone and host protocol is versioned on its own (ACP v1, Noise prologue
`baya/1`). A change that breaks it bumps the major version of both.

## Tags and releases

| Part | Tag | Release | Assets |
| --- | --- | --- | --- |
| App | `app-v<x.y.z>+<build>` | Baya Android x.y.z (build) | `Baya-Android.apk`, `SHA256SUMS.txt` |
| Host | `host-v<x.y.z>` | Baya host x.y.z | `baya-<platform>-<arch>[.exe]`, `SHA256SUMS` |

App releases are marked as pre-releases. The app's update check reads only
`app-v…` tags, and only an APK attached to this repository's release.

### Releasing the app

1. Raise `version` in `app/pubspec.yaml` (the build number by one).
2. Commit and push `main`.
3. Tag and push: `git tag 'app-v<x.y.z>+<build>' && git push origin 'app-v<x.y.z>+<build>'`.

The `App release` workflow checks that the tag matches `pubspec.yaml`,
builds the ARM64 APK, checks that it is signed with the release key and
carries that version, attaches build provenance and publishes it with its
checksum. It needs the release key as repository secrets, set once:

```sh
base64 -w0 release.jks | gh secret set ANDROID_KEYSTORE
gh secret set ANDROID_KEYSTORE_PASSWORD
gh secret set ANDROID_KEY_ALIAS
gh secret set ANDROID_KEY_PASSWORD
```

Without them, release from Windows instead:
`.\scripts\build-app-windows.ps1`, then
`.\scripts\release-app-windows.ps1 -Apk "$env:USERPROFILE\Downloads\Baya-Android.apk" -NotesFile notes.md -Publish`,
which runs the same checks before it publishes.

### Releasing the host

1. Raise `version` in `host/package.json`, commit and push `main`.
2. Tag and push: `git tag host-v<x.y.z> && git push origin host-v<x.y.z>`.

The `Host binaries` workflow builds the single-file `baya` for Linux (x64,
arm64), Windows (x64) and macOS (arm64, x64), checks that each one runs,
attaches build provenance and publishes them with their checksums. Installed
binaries update themselves with `baya update`.

The binaries are signed once these secrets exist (until then macOS gets an
ad-hoc signature and Windows none):

- macOS, Developer ID and notarisation: `APPLE_CERTIFICATE` (the .p12,
  base64), `APPLE_CERTIFICATE_PASSWORD`, `APPLE_IDENTITY`, `APPLE_ID`,
  `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`;
- Windows, Authenticode: `WINDOWS_CERTIFICATE` (the .pfx, base64),
  `WINDOWS_CERTIFICATE_PASSWORD`.

Anyone can check that a download was built here:
`gh attestation verify <file> --repo wianger/baya`.
