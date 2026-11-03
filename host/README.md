# Baya Host

`@wianger/baya` is the CLI and resident host. To phones it is an ACP agent; to
the agents it runs (any command that speaks ACP) it is an ACP client. See
[PROTOCOL.md](../PROTOCOL.md).

## How phones reach the host

Over Tailscale, with nothing else in between. The host listens on loopback
and `tailscale serve` publishes it at
`https://<computer>.<tailnet>.ts.net/baya-pair/<label>`, where the label is
`windows`, `wsl`, `linux` or `macos` (so a Windows and a WSL host can share
one computer). Once per host:

```text
tailscale serve --bg --set-path /baya-pair/<label> http://127.0.0.1:<port>/baya-pair/<label>
```

The port is 7481 for Windows and 7480 otherwise (`BAYA_TAILNET_PORT`
overrides it); `baya doctor` prints the exact command. Under that path:

- `GET …/info` and `GET …/pair` describe the host and issue a pairing code,
  only to devices signed in to the same Tailscale account;
- `…/direct` is the phone's WebSocket: JSON-RPC inside a Noise session,
  end-to-end encrypted between the phone and the host.

Pairing codes (scanned or fetched by typing the computer's name in the app)
carry the `…/direct` address, and the phone connects there afterwards.

## Commands

```text
baya                     start in the background; shows a pairing code if no phone is paired
baya pair                pairing code for another phone   (--ttl 10-600)
baya status              host, phones and sessions
baya open [folder]       add a session                    (--agent <id>)
baya close <session>     remove a session and its history (id prefix or title)
baya agents              configured agents
baya agents add <id> [--name <name>] -- <command> [args…]
baya agents remove <id>
baya agents default <id>
baya devices             paired phones
baya unpair <phone>      revoke a phone, at once          (name or key prefix)
baya start | stop | restart
baya logs [-f]           host log
baya doctor              Tailscale, identity, agents and pairing checks with fixes
baya autostart on|off    start at login
```

`--json` gives machine-readable output for `status`, `devices`, `agents`,
`pair` and `doctor`. Output is colored only on a terminal and honours
`NO_COLOR`. `baya serve` runs the host in the foreground (used by autostart).

`baya autostart on` starts the host at login without administrator rights:

- Windows: the `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` entry
  `BayaHost`, launched through a hidden PowerShell process.
- Linux: the systemd user unit `~/.config/systemd/user/baya.service`
  (restarted on failure; `loginctl enable-linger` keeps it running while
  logged out).
- macOS: the LaunchAgent `~/Library/LaunchAgents/dev.baya.host.plist`
  (restarted on failure).

The service captures the current `PATH`, so run it from the shell where your
agents' commands resolve.

Agent processes start when a session is used and stop after twenty idle
minutes. If one exits, the session stays; the next prompt starts it again and
the host reopens the agent's own session (`session/load` or `session/resume`)
when the agent supports it.
The background host writes `$BAYA_HOME/logs/host.log` (`baya logs`). The control socket is loopback-only and protected by
a random token stored with owner-only permissions.

## State

The state directory defaults to `~/.baya` and may be overridden with
`BAYA_HOME`. It contains:

```text
config.json        agents and the default agent
peers.json         paired phones
sessions.json      sessions
sessions/<id>.json transcripts, replayed to phones on session/load
runtime/
logs/
```

Pairing capability tokens are single-use and stored under the Baya runtime
directory.

## Environment

```text
BAYA_HOME
BAYA_TAILNET_PORT
BAYA_ALLOW_FILE_IDENTITY=1
```

## Development

```powershell
pnpm install --ignore-scripts
pnpm dev -- status   # runs src/cli.ts directly; Node strips the types
pnpm lint            # Biome: lint + format check (pnpm format to fix)
pnpm typecheck       # src and tests
pnpm test
pnpm build           # tsc emits dist/ for publishing
pnpm build:binary    # the single-file executable for this platform, in build/bin
```

The source is erasable TypeScript (`erasableSyntaxOnly`), imported with `.ts`
extensions, so Node runs it without a build step or loader.

The pnpm setup ignores native install scripts. The keyring package's prebuilt
binaries are sufficient; use `--ignore-scripts` if a newer pnpm reports ignored
build policy entries before install.
