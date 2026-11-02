# Baya Android

Flutter Android client for the standalone Baya host.

The package ID is `dev.wianger.baya`, signed with the personal development key.

The app discovers the GitHub release channel at
<https://github.com/wianger/baya/releases> and accepts only uploaded
`Baya-Android.apk` assets whose URL belongs to `wianger/baya`.

Run:

```powershell
flutter pub get
flutter analyze
flutter test
flutter build apk --release --target-platform android-arm64
```

For the signing-aware build and publish flow, use the scripts at the repository
root described in [../docs/mobile-dev.md](../docs/mobile-dev.md).
