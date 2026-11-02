# Baya

Baya is a standalone host and Android client for controlling coding-agent
conversations from a phone. It no longer depends on being installed as a Pi
extension. The `baya` CLI owns local sessions, pairing, phone connections, and
workspace/file access; Pi, Codex, and DeepSeek Harness are launched as ordinary
child processes.

## Components

| Path | Purpose |
|---|---|
| `host/` | Standalone TypeScript CLI and resident session host, published as the `baya` executable |
| `app/` | Android Flutter client (`dev.wianger.baya`) |
| `branding/` | Baya SVG and PNG identity assets |
| `PROTOCOL.md` | Canonical wire protocol and security model |

## Quick start

Requirements:

- Node.js 22.19 or newer
- pnpm 10 or newer
- At least one agent on `PATH`: `pi`, `codex`, or DeepSeek Harness `dsh`
- [Tailscale](https://tailscale.com/download) on the computer and the phone,
  signed in to the same account

Build and link the CLI:

```powershell
cd host
pnpm install --ignore-scripts
pnpm build
pnpm add --global .
baya doctor
```

Phones reach the computer over Tailscale, with nothing in between. Publish
the host once with `tailscale serve` (`baya doctor` prints the exact command;
from WSL, run it on Windows):

```powershell
tailscale serve --bg --set-path /baya-pair/windows http://127.0.0.1:7481/baya-pair/windows
```

Start Baya in a project folder. The first time, it prints a pairing code;
scan it with the app and you are done:

```powershell
cd C:\code\project
baya
```

Three ways to pair, all equally secure:

- **Scan** the QR code it prints.
- **Tailscale name**: tap *Use Tailscale* in the app and type the computer's
  name. The host issues pairing codes only to devices of the same Tailscale
  account (serve names the caller in `Tailscale-User-Login`). A Windows and a
  WSL Baya on one computer both appear, and the app stays connected to both.
- **Link**: tap the `baya://pair?…` link on the phone, or paste it.

Manage paired phones. Unpairing takes effect immediately, including for a
stream that is already running:

```powershell
baya devices
baya unpair Pixel
```

Start Baya at login (a Windows Run entry, a systemd user unit, or a macOS
LaunchAgent; no administrator rights):

```powershell
baya autostart on     # baya autostart off to remove it
```

The host stores its state in `%USERPROFILE%\.baya` (or `$BAYA_HOME` when set).

## Pi integration

Baya starts Pi with native RPC mode:

```text
pi --mode rpc --approve --session-id <id> --name <name>
```

It does not run `pi install`, does not pass `-e`, and does not load a Baya
extension into Pi. That separation lets the normal Pi CLI and Baya host evolve
independently.

## Android

Build the release APK:

```powershell
scripts\build-mobile-windows.ps1
```

The package ID is `dev.wianger.baya`. Release artifacts are named
`Baya-Android.apk` and published from this repository; the app checks them for
updates.

## Security

Every frame between the phone and the computer is end-to-end encrypted
(X25519 + ChaCha20-Poly1305, keyed by the paired Ed25519 identities), on top
of Tailscale's own encryption, so not even `tailscale serve` can read or forge
it. See [PROTOCOL.md](PROTOCOL.md#end-to-end-encryption-v1).

## Validation

```powershell
cd host
pnpm typecheck
pnpm test
pnpm build

cd ..\app
flutter pub get
flutter analyze
flutter test
```
