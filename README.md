# Baya

Baya is a standalone host and Android client for controlling coding-agent
conversations from a phone. It no longer depends on being installed as a Pi
extension. The `baya` CLI owns local sessions, pairing, relay connectivity, and
workspace/file access; Pi, Codex, and DeepSeek Harness are launched as ordinary
child processes.

> Baya uses the Remote Pi wire protocol for compatibility with the existing
> signed Android application. Protocol compatibility does not make Baya a Pi
> plugin or require Remote Pi to be installed.

## Components

| Path | Purpose |
|---|---|
| `host/` | Standalone TypeScript CLI and resident session host, published as the `baya` executable |
| `app/` | Android Flutter client. The Android package ID remains `dev.wianger.remotepi` so signed updates install in place |
| `relay/` | Self-hostable Rust relay compatible with the Baya/Remote Pi protocol |
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
pnpm link --global
baya doctor
```

Start the resident host and keep it running:

```powershell
baya start --cwd C:\code\project
baya status
baya pair
```

On Windows, install the per-user logon task:

```powershell
baya install-service
```

The host stores its state in `%USERPROFILE%\.baya` (or `$BAYA_HOME` when set).
On first use it migrates the existing Remote Pi identity from the OS keyring
and copies `peers.json` and the relay setting, preserving current pairings when
possible.

## Pi integration

Baya starts Pi with native RPC mode:

```text
pi --mode rpc --approve --session-id <id> --name <name>
```

It does not run `pi install`, does not pass `-e`, and does not load a Baya
extension into Pi. That separation lets the normal Pi CLI and Baya host evolve
independently.

## Android

The existing Android package receives the Baya release channel:

```powershell
scripts\build-mobile-windows.ps1
```

The build preserves the existing `dev.wianger.remotepi` package ID and signing
certificate, so Android upgrades the current installation in place. Release
artifacts are named `Baya-Android.apk` and published from this repository.

## Relay

The default configuration uses the existing compatible public relay. For
private infrastructure, build the included relay and point Baya at it:

```powershell
docker build -t baya-relay relay
docker run -d --name baya-relay -p 3000:3000 -v baya-data:/data baya-relay
baya set-relay http://127.0.0.1:3000
```

Baya authenticates the WebSocket and protects it in transit with TLS, but the
inner payload is only base64-encoded and the relay is not an end-to-end
encryption boundary. Use a trusted or self-hosted relay for private source code
and credentials.

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
