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
baya agents [--json]
baya doctor [--json]
baya set-relay <http(s)|ws(s) URL>
baya install-service
baya uninstall-service
```

`baya` without a command starts the foreground host using the current folder.
`baya start` detaches a resident host and writes logs to
`$BAYA_HOME/logs/host.log`. The control socket is loopback-only and protected by
a random token stored with owner-only permissions.

## State and migration

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

Existing `~/.pi/remote` relay settings, file identities, keyring identities,
and paired-device records are read during migration. Baya never modifies the
old directory. Pairing capability tokens are single-use and stored under the
Baya runtime directory.

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

Legacy `REMOTE_PI_*` overrides remain accepted for migration compatibility.

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
