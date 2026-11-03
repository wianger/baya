# Baya Wire Protocol

Baya speaks the [Agent Client Protocol](https://agentclientprotocol.com) (ACP
v1) end to end:

```text
phone (ACP client) ⇄ Baya host (ACP agent to the phone, ACP client to agents) ⇄ agent processes
```

To the phone, a computer is one ACP agent whose sessions run on whichever
agent each was created with. The host starts an agent process when a session
is used, keeps the transcript, and fans updates and permission questions out
to every phone that has the session open. Baya's own features (pairing,
folders, files, live session list) are `_baya/*` extension methods and
`_meta.baya` fields, as ACP prescribes for extensions.

## Agents

An agent is any command that speaks ACP over stdio, set up per computer:

```sh
baya agents add claude --name "Claude Code" -- CLAUDE_CODE_EXECUTABLE=/path/to/claude claude-agent-acp
baya agents add codex --name Codex -- CODEX_PATH=/path/to/codex codex-acp
baya agents add deepseek --name DeepSeek -- dsh --profile acp
```

Leading `NAME=value` words are stored as the agent's environment. The host is their client. It sends `initialize` with no file-system or
terminal capability, so agents use their own tools on the computer. A
session's agent process starts on first use and stops after twenty idle
minutes; when it starts again the host reopens the agent's session with
`session/load` (swallowing the replay) or `session/resume`, and otherwise
starts a new one and adds a notice that the agent lost its context.

## Reaching the host

The host listens on loopback; `tailscale serve` publishes it at
`https://<computer>.<tailnet>.ts.net/baya-pair/<label>`, where the label is
`windows`, `wsl`, `linux` or `macos`, so two hosts can share one computer.
Under that path:

- `GET …/info` → `{"label","name","key"}` and `GET …/pair` → a pairing code,
  only for callers whose `Tailscale-User-Login` is the computer's own account
  (403 otherwise);
- `…/direct` is the phone's WebSocket.

## Security

Each computer has one long-lived Ed25519 identity, stored in the operating
system keyring (or a protected file on headless machines). Each phone has its
own Ed25519 owner identity.

The WebSocket first proves the phone's key with JSON text frames:

```json
{"type":"hello","pubkey":"base64-ed25519"}
{"type":"challenge","nonce":"base64-32-bytes"}
{"type":"auth","sig":"base64-ed25519-signature"}
```

After that every frame is binary and sealed, in both directions.

### End-to-end encryption (v2)

Both sides convert their Ed25519 identity to X25519 (RFC 8032 §5.1.5 for the
private scalar, the birational map for the public key) and derive one key per
phone/computer pair:

```text
key   = HKDF-SHA256(ikm  = X25519(self, peer),
                    salt = "baya-e2e-v2",
                    info = min(ed_pk_a, ed_pk_b) || max(ed_pk_a, ed_pk_b))
frame = 0xBE 0x02 || nonce(12) || ChaCha20-Poly1305(ts_ms_be64 || json)
aad   = "baya-e2e-v2|" + ("p2h" | "h2p")
```

`json` is one JSON-RPC 2.0 message. The phone learns the computer key from
the pairing code and the computer learns the phone key from the handshake, so
nothing in between, `tailscale serve` included, can read, forge or redirect a
frame. The direction in the AAD stops reflection; receivers drop frames more
than five minutes old or whose nonce they have seen. The test vector is
`.orchestration/contracts/e2e_v2.json`.

The key is static (no forward secrecy): a leaked identity key exposes recorded
traffic. Rotating the computer identity and re-pairing replaces it.

The host closes the socket with:

- `4001 clock_skew:<minutes>` for an authentic frame outside the window (the
  phone's clock is wrong);
- `4003 unpaired` when the phone's pairing is revoked (`baya unpair`), at once.

## Pairing

`baya pair` (or `GET …/pair`) issues a random single-use token, valid for up
to ten minutes:

```text
baya://pair?t=<token>&epk=<computer key>&n=<computer name>&e=<…/direct address>
```

The phone connects with its own key and calls:

```json
{"jsonrpc":"2.0","id":1,"method":"_baya/pair","params":{"token":"…","deviceName":"Pixel"}}
→ {"jsonrpc":"2.0","id":1,"result":{"hostname":"studio"}}
```

Failures are JSON-RPC error `-32000` with `data.reason` `token_expired`,
`token_consumed` or `token_unknown`. Until a key is paired, `_baya/pair` is the
only method it may call; anything else fails with `-32000` and
`data.reason: "unpaired"`.

## Phone → host

The phone sends `initialize` (protocol version 1). The answer describes the
computer and its agents:

```json
{
  "protocolVersion": 1,
  "agentInfo": {"name": "baya", "title": "Baya", "version": "4.0.0"},
  "agentCapabilities": {
    "loadSession": true,
    "promptCapabilities": {"image": true},
    "sessionCapabilities": {"list": {}, "resume": {}, "close": {}, "delete": {}}
  },
  "authMethods": [],
  "_meta": {"baya": {"hostname": "studio", "agents": [{"id": "claude", "name": "Claude Code", "available": true}]}}
}
```

Standard ACP methods, with Baya's meaning:

| Method | |
|---|---|
| `session/list` | Every session on the computer, newest first. `SessionInfo._meta.baya` carries `agent`, `agentName`, `working`, `running` and, when the agent could not start, `error`. |
| `session/new` | `{cwd, mcpServers, _meta.baya.agent}`; the configured default agent when omitted. |
| `session/load` | Replays the transcript as `session/update` notifications, then answers with `configOptions`, `modes` and `_meta.baya` (`agentName`, `title`, `working`, `promptCapabilities`). The phone is attached until `session/close`. |
| `session/resume` | Attaches without the replay. |
| `session/prompt` | Queued behind a running turn. `_meta.baya.messageId` names the echoed `user_message_chunk`s. |
| `session/cancel` | Ends the turn and drops queued prompts. |
| `session/set_config_option`, `session/set_mode` | Passed to the agent; other attached phones get the matching update. |
| `session/close` | Detaches this phone. |
| `session/delete` | Stops the agent and deletes the session and its history. |

Baya methods:

| Method | Params | Result |
|---|---|---|
| `_baya/browse` | `{path?, showHidden?}` | `{path, parent, home, roots, directories:[{name,path}], truncated}` |
| `_baya/files` | `{sessionId, path?, showHidden?}` | `{root, path, parent, entries:[{name,path,type,size,modifiedAt}], truncated}` |
| `_baya/read_file` | `{sessionId, path}` | `{name, path, size, modifiedAt, content, binary, truncated}` (256 KiB at most) |

Folder access stays read-only, and `_baya/files` cannot leave the session's
folder.

## Host → phone

`session/update` notifications reach every phone attached to the session,
with the session's Baya id. Conversation updates (`user_message_chunk`,
`agent_message_chunk`, `agent_thought_chunk`, `tool_call`,
`tool_call_update`, `plan`, `notice`, `compaction_update`,
`compaction_summary_chunk`) are also kept for replay, folded so each message
and each tool call is stored once in its final state. State updates
(`available_commands_update`, `usage_update`, `config_option_update`,
`current_mode_update`, `session_info_update`) are applied to the session and
the latest commands and usage follow every replay.

`session/request_permission` goes to every attached phone, and to phones that
attach while it is open. The first answer is passed to the agent; the host
withdraws the question from the other phones with `$/cancel_request`.

Every paired phone also gets the session list as it changes:

```json
{"jsonrpc":"2.0","method":"_baya/session_changed","params":{"session":{"sessionId":"…","cwd":"/code/app","title":"Fix login","updatedAt":"…","_meta":{"baya":{"agent":"claude","agentName":"Claude Code","working":true,"running":true}}}}}
{"jsonrpc":"2.0","method":"_baya/session_removed","params":{"sessionId":"…"}}
```

A session's title is the start of its first prompt until the agent names it
(`session_info_update`).

## State

The host keeps `$BAYA_HOME` (default `~/.baya`):

```text
config.json        agents and the default agent
peers.json         paired phone keys
sessions.json      sessions: id, cwd, agent, title, the agent's session id
sessions/<id>.json each session's transcript
runtime/           control socket info, pending pairing token
logs/host.log
```

The phone keeps its pairings and each computer's last session list, so the
list shows before a connection is up. Conversations always come from the
computer.
