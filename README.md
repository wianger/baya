# Baya

Baya drives coding agents on your computers from your phone. It speaks the
[Agent Client Protocol](https://agentclientprotocol.com) (ACP) end to end: any
agent with an ACP command (Claude Code, Codex, Pi, DeepSeek Harness, …)
runs on the computer, and the phone is an ACP client to it, over Tailscale and
end-to-end encrypted.

## Components

| Path | Purpose |
|---|---|
| `host/` | Standalone TypeScript CLI and resident session host, published as the `baya` executable |
| `app/` | Android Flutter client (`dev.wianger.baya`) |
| `branding/` | Baya SVG and PNG identity assets |
| `PROTOCOL.md` | Wire protocol (ACP plus Baya's extensions) and security model |

## Quick start

Requirements:

- Node.js 22.19 or newer
- pnpm 10 or newer
- An agent that speaks ACP (see [Agents](#agents))
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

Add an agent, then start Baya. The first time, it prints a pairing code;
scan it with the app and you are done:

```powershell
baya agents add claude --name "Claude Code" -- npx -y @agentclientprotocol/claude-agent-acp
baya
```

Start sessions from the app (pick a folder and an agent), or from the
computer with `baya open <folder>`.

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

## Agents

An agent is any command that speaks ACP on stdin/stdout. Baya starts it in the
session's folder when the session is used and stops it after twenty idle
minutes; the conversation stays on the computer either way.

```powershell
baya agents add claude --name "Claude Code" -- npx -y @agentclientprotocol/claude-agent-acp
baya agents add codex --name Codex -- npx -y @agentclientprotocol/codex-acp
baya agents add pi --name Pi -- npx -y pi-acp
baya agents add deepseek --name DeepSeek -- dsh --profile acp
baya agents                  # list them; the first is the default
baya agents default codex
```

Each agent signs in the way it normally does on that computer. Model,
reasoning effort and modes in the app are the agent's own ACP settings, and
its permission questions appear on every phone that has the session open.

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
it. See [PROTOCOL.md](PROTOCOL.md#end-to-end-encryption-v2).

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
