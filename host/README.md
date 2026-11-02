# Baya Host

`@wianger/baya` is the standalone CLI and resident host. It has no dependency on
Pi's extension API and can host Pi, Codex, and DeepSeek Harness sessions in the
same process tree.

## Commands

```text
baya serve
baya start
baya stop
baya status
baya sessions [--json]
baya new [path] --agent pi|codex|deepseek --name <name>
baya open <path> --agent pi|codex|deepseek
baya remove <id>
baya pair [id] --ttl <10-600>
baya devices [--json]
baya unpair <name|key-prefix>
baya agents [--json]
baya doctor [--json]
baya set-relay <http(s)|ws(s) URL>
baya install-service
baya uninstall-service
```

`install-service` starts the host at login without administrator rights:

- Windows: the `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` entry
  `BayaHost`, launched through a hidden PowerShell process.
- Linux: the systemd user unit `~/.config/systemd/user/baya.service`
  (restarted on failure; `loginctl enable-linger` keeps it running while
  logged out).
- macOS: the LaunchAgent `~/Library/LaunchAgents/dev.baya.host.plist`
  (restarted on failure).

The service captures the current folder and `PATH`, so run it from the shell
where `pi`, `codex`, or `deepseek` resolve.

`baya` without a command starts the foreground host using the current folder.

If an agent process exits unexpectedly, the host keeps the session registered
and restarts it with backoff (1 s, 5 s, 15 s, then every minute). The relay
connection is independent: local sessions start even while the relay is
unreachable, and the host reconnects in the background.
`baya start` detaches a resident host and writes logs to
`$BAYA_HOME/logs/host.log`. The control socket is loopback-only and protected by
a random token stored with owner-only permissions.

## State

The state directory defaults to `~/.baya` and may be overridden with
`BAYA_HOME`. It contains:

```text
config.json
peers.json
sessions.json
sessions/
runtime/
logs/
```

Pairing capability tokens are single-use and stored under the Baya runtime
directory.

## Agents

- Pi uses its documented JSONL RPC mode and resumes the exact persisted project
  session ID.
- Codex uses the app-server protocol and persists its thread mapping under the
  Baya session state.
- DeepSeek Harness uses its ACP profile and resolves the desktop-bundled CLI when
  `dsh` is not on `PATH`.

Environment overrides:

```text
BAYA_HOME
BAYA_RELAY
BAYA_DSH_BIN
BAYA_DSH_INSPECTOR_PORT
BAYA_ALLOW_FILE_IDENTITY=1
```

## Development

```powershell
pnpm install --ignore-scripts
pnpm typecheck
pnpm test
pnpm build
```

The pnpm setup ignores native install scripts. The keyring package's prebuilt
binaries are sufficient; use `--ignore-scripts` if a newer pnpm reports ignored
build policy entries before install.
