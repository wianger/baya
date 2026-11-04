<div align="center">

<img src="branding/baya-mark.svg" width="112" alt="Baya">

# Baya

### Your coding agents, from your phone.

**Claude Code, Codex, Pi, DeepSeek Harness — any agent that speaks ACP.**<br>
Start sessions on your computers, follow them live, answer their questions,
review and commit their changes, give one task to several agents side by
side, and open the site they are building on your phone.

[![App](https://img.shields.io/github/v/release/wianger/baya?filter=app-v*&include_prereleases&label=app&color=111111)](https://github.com/wianger/baya/releases?q=app-v)
[![Host](https://img.shields.io/github/v/release/wianger/baya?filter=host-v*&label=host&color=111111)](https://github.com/wianger/baya/releases?q=host-v)
[![License](https://img.shields.io/badge/license-MIT-111111)](LICENSE)<br>
![Android](https://img.shields.io/badge/Android-3DDC84?logo=android&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-000000?logo=apple&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-0078D4?logo=windows&logoColor=white)
![Linux](https://img.shields.io/badge/Linux-FCC624?logo=linux&logoColor=black)

</div>

Baya drives coding agents on your computers from your phone. It speaks the
[Agent Client Protocol](https://agentclientprotocol.com) (ACP) end to end: any
agent with an ACP command (Claude Code, Codex, Pi, DeepSeek Harness, …)
runs on the computer, and the phone is an ACP client to it, over Tailscale and
end-to-end encrypted.

## What it does

- **Sessions on any of your computers**: pick a folder and an agent; follow
  its thinking, tool calls, diffs and terminals as they stream; answer its
  permission questions and forms.
- **Edit and branch**: put a sent message back in the composer to change
  and resend; with Claude Code and Codex, branch from it instead, into a new
  session that holds only the conversation before it.
- **Parallel runs**: give the same task to Claude Code, Codex and Pi at
  once, each in its own git worktree and branch, then compare their replies
  and changes on one board and send follow-ups to all of them.
- **Web preview**: a dev server on the computer (`localhost:5173`) opens in
  the app, hot reload included, without exposing it to the network;
  `localhost` links the agent writes open there too.
- **Files both ways**: send a PDF, log or archive from the phone into the
  session's folder (or attach it to a prompt for any agent), and save or
  share any file of the session on the phone. Up to 100 MB, over the same
  encrypted connection.
- **Review**: per-file diffs, revert a hunk, commit, push and open a pull
  request.
- **Private**: Noise end-to-end encryption over Tailscale; nothing goes
  through a server of ours.

## Components

| Path | Purpose |
|---|---|
| `host/` | The `baya` command and resident host (TypeScript), shipped as one executable |
| `app/` | The Android app (Flutter, `dev.wianger.baya`) |
| `branding/` | The mark, icon layers and banner, generated from one script |
| `PROTOCOL.md` | Wire protocol (ACP plus Baya's extensions) and security model |
| `docs/` | [Development](docs/development.md) and [releasing](docs/releasing.md) |

## Quick start

Requirements:

- An agent that speaks ACP (see [Agents](#agents))
- [Tailscale](https://tailscale.com/download) on the computer and the phone,
  signed in to the same account

Download `baya` for your computer from the latest `host-v…`
[release](https://github.com/wianger/baya/releases) (one file, Node
included: `baya-linux-x64`, `baya-linux-arm64`, `baya-darwin-arm64`,
`baya-darwin-x64` or `baya-win32-x64.exe`), put it on your PATH as `baya`
(`chmod +x` it on Linux and macOS), and check the setup. `baya update`
keeps it current later.

```powershell
baya doctor
```

To build it yourself instead (Node.js 24 and pnpm 10 or newer):

```powershell
cd host
pnpm install --ignore-scripts
pnpm build:binary      # build/bin/baya-<platform>-<arch>
```

Or run it from source with Node: `pnpm build`, then `pnpm add --global .`.

Phones reach the computer over Tailscale, with nothing in between. Publish
the host once with `tailscale serve` (`baya doctor` prints the exact command;
from WSL, run it on Windows):

```powershell
tailscale serve --bg --set-path /baya-pair/windows http://127.0.0.1:7481/baya-pair/windows
```

Set up an agent (see [Agents](#agents)), then start Baya. The first time, it
prints a pairing code; scan it with the app and you are done:

```powershell
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

```sh
# Adapters that drive the CLIs you already have:
npm i -g @agentclientprotocol/claude-agent-acp @agentclientprotocol/codex-acp pi-acp
baya agents add claude --name "Claude Code" -- CLAUDE_CODE_EXECUTABLE=$(which claude) claude-agent-acp
baya agents add codex --name Codex -- CODEX_PATH=$(which codex) codex-acp
baya agents add pi --name Pi -- pi-acp
baya agents add deepseek --name DeepSeek -- dsh --profile acp
baya agents                  # list them; the first is the default
baya agents default codex
```

`claude`, `codex` and `pi` do not speak ACP themselves; each adapter
translates. `NAME=value` words before the command become the agent's
environment: here they make the adapters run your installed CLIs, with your
sign-in and settings, instead of the copies they bundle.

Each agent signs in the way it normally does on that computer. Model,
reasoning effort and modes in the app are the agent's own ACP settings, and
its permission questions appear on every phone that has the session open.

## Android

Install `Baya-Android.apk` from the latest `app-v…`
[release](https://github.com/wianger/baya/releases); the app checks there for
updates. The package ID is `dev.wianger.baya`. Building it yourself is
described in [docs/development.md](docs/development.md), releasing in
[docs/releasing.md](docs/releasing.md).

## Security

Every frame between the phone and the computer is end-to-end encrypted with
the Noise protocol (`Noise_IK_25519_ChaChaPoly_SHA256`): mutual
authentication with the paired identities and forward secrecy, on top of
Tailscale's own encryption, so not even `tailscale serve` can read or forge
it. See [PROTOCOL.md](PROTOCOL.md#noise).

## Development

See [docs/development.md](docs/development.md) for building and testing both
parts, and [docs/releasing.md](docs/releasing.md) for branches, versions and
releases.
