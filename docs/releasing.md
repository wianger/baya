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
2. Commit, push `main`, keep the checkout clean.
3. Build: `.\scripts\build-app-windows.ps1`.
4. Release:

   ```powershell
   .\scripts\release-app-windows.ps1 `
     -Apk "$env:USERPROFILE\Downloads\Baya-Android.apk" `
     -NotesFile notes.md -Publish
   ```

   The script checks that the APK's version matches `pubspec.yaml`, that it
   is signed with the release key, and that its build number is new. It then
   uploads the APK with its checksum to a draft, verifies the upload and
   publishes it.

### Releasing the host

1. Raise `version` in `host/package.json`, commit and push `main`.
2. Tag and push: `git tag host-v<x.y.z> && git push origin host-v<x.y.z>`.

The `Host binaries` workflow builds the single-file `baya` for Linux (x64,
arm64), Windows (x64) and macOS (arm64, x64), checks that each one runs, and
publishes them with their checksums.
