# Baya Android

Flutter Android client for the standalone Baya host.

The package ID is `dev.wianger.baya`, signed with the release key.

The app checks <https://github.com/wianger/baya/releases> for updates: it reads
only `app-v<version>+<build>` releases and accepts only an uploaded
`Baya-Android.apk` whose URL belongs to `wianger/baya`.

Run:

```powershell
flutter pub get
flutter analyze
flutter test
flutter build apk --release --target-platform android-arm64
```

Signed release builds and releases: [../docs/development.md](../docs/development.md)
and [../docs/releasing.md](../docs/releasing.md).
