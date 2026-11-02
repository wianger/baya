# Baya

Baya is a standalone host and Android client for controlling coding-agent
conversations from a phone. It no longer depends on being installed as a Pi
extension. The `baya` CLI owns local sessions, pairing, relay connectivity, and
workspace/file access; Pi, Codex, and DeepSeek Harness are launched as ordinary
child processes.

## Components

| Path | Purpose |
|---|---|
| `host/` | Standalone TypeScript CLI and resident session host, published as the `baya` executable |
| `app/` | Android Flutter client (`dev.wianger.baya`) |
| `relay/` | Self-hostable Rust relay for the Baya protocol |
| `branding/` | Baya SVG and PNG identity assets |
| `PROTOCOL.md` | Canonical wire protocol and security model |

## Quick start

Requirements:

- Node.js 22.19 or newer
- pnpm 10 or newer
- At least one agent on `PATH`: `pi`, `codex`, or DeepSeek Harness `dsh`

Build and link the CLI:

```powershell
cd host
pnpm install --ignore-scripts
pnpm build
pnpm add --global .
baya doctor
```

Start Baya in a project folder. The first time, it prints a pairing code;
scan it with the app and you are done:

```powershell
cd C:\code\project
baya
```

Three ways to pair, all equally secure:

- **Scan** the QR code it prints.
- **Tailscale**: if the phone and the computer share a Tailscale account,
  tap *Use Tailscale* in the app and type the computer's name. The host
  issues pairing codes only to devices of the same Tailscale account: on its
  tailnet address (port 7480, checked with `tailscale whois`) and, where
  inbound connections are firewalled (WSL), through
  `tailscale serve --bg --set-path /baya-pair http://127.0.0.1:7480/baya-pair`
  (HTTPS; the caller is named by serve's `Tailscale-User-Login`).
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

## Relay

Phones and hosts meet at a relay, and every Baya host has one built in.
When the relay address is local (`baya relay http://127.0.0.1:3000`), the
first Baya on the machine to bind that port serves it and the others connect
to it; if it exits, the next one takes over. With Tailscale, expose it once:

```powershell
tailscale serve --bg http://127.0.0.1:3000
baya relay http://127.0.0.1:3000 --public https://<machine>.<tailnet>.ts.net
```

The phone then talks straight to your computer, with no relay service to run.

For computers that are not on a tailnet with the phone, run the standalone
relay in `relay/` on a reachable server:

```powershell
docker build -t baya-relay relay
docker run -d --name baya-relay -p 3000:3000 -v baya-data:/data baya-relay
baya relay https://relay.example.com
```

Both speak the same protocol. Messages between the phone and the computer
are end-to-end encrypted (X25519 + ChaCha20-Poly1305, keyed by the paired
Ed25519 identities), so a relay only routes ciphertext and cannot forge
messages. See [PROTOCOL.md](PROTOCOL.md#end-to-end-encryption-v1).

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

cd ..\relay
cargo test
```
