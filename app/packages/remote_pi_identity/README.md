# Android owner identity

This local Flutter package persists Baya's Owner Ed25519 key in Android Block
Store so a restored device can recover the same owner key after Google Backup.
It is internal to the Baya monorepo and is not published to pub.dev.

The package directory, channel names, and Kotlin namespace keep their historical
Remote Pi names. Those identifiers are compatibility boundaries for data already
present on installed Android devices. User-visible branding is Baya.

## API

```dart
final store = MethodChannelOwnerIdentityStore();

if (!await store.isSyncAvailable()) {
  // Ask the user to enable Google Backup and finish device lock setup.
  return;
}

final identity = await store.load();
if (identity == null) {
  // Generate 32-byte public and secret halves with the app crypto layer.
  await store.save(OwnerIdentity(ownerPk: publicKey, ownerSk: secretKey));
}
```

`OwnerIdentity` serializes to exactly 64 bytes (`ownerPk || ownerSk`). This
package does not generate keys, perform relay authentication, or manage paired
computers.

## Android requirements

- Android 14 / API 34 or newer
- Google Play Services
- A signed-in Google account with Android Backup enabled
- A device lock

Block Store restores data on a new device; it does not provide live key sync
between two concurrently used Android devices.
