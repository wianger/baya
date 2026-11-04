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

Leading `NAME=value` words are stored as the agent's environment; an
agent's `mcpServers` in `config.json` go with every session it starts.

The host is the agents' ACP client and implements the whole client side:

- `fs/read_text_file` (with `line` and `limit`) and `fs/write_text_file`;
- `terminal/create`, `terminal/output`, `terminal/wait_for_exit`,
  `terminal/kill` and `terminal/release`, running commands on the computer
  and keeping the last 256 KiB of output (or the agent's `outputByteLimit`);
- `session/request_permission` and `elicitation/create` (form and URL
  modes), answered by a phone;
- `session/update` of every kind, including notices, compaction and
  boolean config options.

A session's agent process starts on first use and stops after twenty idle
minutes; when it starts again the host reopens the agent's session with
`session/load` (swallowing the replay) or `session/resume`, and otherwise
starts a new one and adds a notice that the agent lost its context.

When an agent answers a prompt with `-32000` (authentication required), the
host passes the error on with `data: {"reason":"auth_required","agent":"<id>"}`
and the phone offers the agent's sign-in methods.

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
own Ed25519 owner identity. For Noise both are used as X25519 keys (the
private scalar per RFC 8032 §5.1.5, the public key by the birational map).

### Noise

Every WebSocket frame is binary. The connection opens with a
[Noise](https://noiseprotocol.org/noise.html) handshake:

```text
Noise_IK_25519_ChaChaPoly_SHA256, prologue "baya/1"
  <- s                      the phone knows the computer's key from pairing
  -> e, es, s, ss           payload {"ed25519":"<phone identity, base64>"}
  <- e, ee, se              payload {}
```

One round trip authenticates both sides, and the ephemeral keys give
forward secrecy: a stolen identity key cannot decrypt recorded traffic. The
computer checks that the phone's claimed Ed25519 key maps to the static key
the handshake proved, and uses it as the phone's identity.

After the handshake every frame is one Noise transport message whose
plaintext is a flag byte (`1` for the last piece) and a piece of a JSON-RPC
message, so messages larger than Noise's 64 KiB limit span several frames.
The nonce counters reject any replayed, reordered, dropped or forged frame;
the computer then closes the connection (`4002`). Nothing in between,
`tailscale serve` included, can read or change a byte.

Both implementations are pinned to the cacophony IK vector
(`.orchestration/contracts/noise_ik_vector.json`) and to a Baya handshake
vector (`noise_baya_vector.json`, from `host/test/make-noise-vector.ts`).

The host closes the socket with `4003 unpaired` when the phone's pairing is
revoked (`baya unpair`), at once.

## Pairing

`baya pair` (or `GET …/pair`) issues a random single-use token, valid for up
to ten minutes:

```text
baya://pair?t=<token>&epk=<computer key>&n=<computer name>&e=<…/direct address>
```

The phone connects (the handshake proves its key) and calls:

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
| `session/new` | `{cwd, mcpServers, _meta.baya.agent}`; the configured default agent when omitted. With `_meta.baya.agentSessionId` it adopts one of the agent's own conversations (see `_baya/agent_sessions`) and loads its history. |
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
| `_baya/agent_auth` | `{agent}` | `{authMethods, logout}`: the agent's ACP auth methods; `logout` when it supports signing out |
| `_baya/authenticate` | `{agent, methodId}` | `{}`; the agent restarts signed in |
| `_baya/logout` | `{agent}` | `{}` |
| `_baya/agent_sessions` | `{agent, cwd}` | `{sessions}`: the agent's `session/list` in that folder, without those Baya already has |
| `_baya/git_status` | `{sessionId}` | `{root, branch, upstream, ahead, behind, files:[{path,status,added,removed}]}` for the session's repository |
| `_baya/git_diff` | `{sessionId, path}` | `{path, untracked, hunks:[{header,oldStart,newStart,lines:[{kind,text}]}]}`, against `HEAD` |
| `_baya/git_revert` | `{sessionId, path, hunk?}` | Undoes one hunk in the working tree, or the whole file (a new file is deleted) |
| `_baya/git_commit` | `{sessionId, message}` | `{commit}`: commits every change |
| `_baya/git_push` | `{sessionId}` | `{}`; sets the upstream on the first push |
| `_baya/pr_create` | `{sessionId, title, body?}` | `{url}`, through the GitHub CLI on the computer |

Files the phone attaches to a prompt go as ACP `resource_link` blocks with
`file://` URIs on the computer; the agent reads them itself.

Browsing stays read-only, and `_baya/files` cannot leave the session's
folder; the `git_*` methods act only inside the session's repository.

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

`session/request_permission` and `elicitation/create` go to every attached
phone, and to phones that attach while they are open. The first answer is
passed to the agent; the host withdraws the question from the other phones
with `$/cancel_request`. `elicitation/complete` is passed on as is.

Terminals an agent runs stream to attached phones, at most every 150 ms, and
are kept with the transcript and replayed on attach:

```json
{"jsonrpc":"2.0","method":"_baya/terminal","params":{"sessionId":"…","terminalId":"term-…","output":"…","truncated":false,"exitStatus":{"exitCode":0,"signal":null}}}
```

The phone shows each terminal inside the tool call that embeds it.

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
sessions/<id>.json each session's transcript and terminals
runtime/           control socket info, pending pairing token
logs/host.log
```

The phone keeps its pairings and each computer's last session list, so the
list shows before a connection is up. Conversations always come from the
computer.
