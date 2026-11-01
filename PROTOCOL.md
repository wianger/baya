# Baya Wire Protocol

This document describes the protocol implemented by the standalone Baya host,
the Baya Android client, and the compatible relay in this repository.

Baya reuses the original Remote Pi transport and message vocabulary so the
existing signed Android package can update in place. The host is independent:
it does not install itself into Pi and Pi is launched as a normal RPC child
process.

## Security model

Each computer has one long-lived Ed25519 identity. The identity is stored in
the operating-system keyring, with a protected file fallback for headless
environments. Each mobile installation also has an Ed25519 Owner identity.

All WebSocket connections authenticate with a challenge-response:

```json
{"type":"hello","pubkey":"base64-ed25519","room_id":"...","room_meta":{"name":"...","cwd":"..."}}
{"type":"challenge","nonce":"base64-32-bytes"}
{"type":"auth","sig":"base64-ed25519-signature"}
```

The relay accepts routing traffic for a paired computer only from a saved peer
key. Pairing requests are the only pre-pair message admitted to the host.

The relay protects traffic in transit with TLS and cannot route without valid
Ed25519 authentication. The inner message is base64-encoded JSON, not encrypted.
The relay operator controls its endpoint and executable, so this is not an
end-to-end encryption boundary. Use a trusted or self-hosted relay.

## Relay envelope

After authentication, routed application messages use one JSON object per
WebSocket text frame:

```json
{
  "peer": "destination-mobile-ed25519-public-key",
  "ct": "base64-json-application-message"
}
```

`ct` decodes to one of the message types below. Unknown fields are ignored by
the current clients. Unknown message types receive an `error` or
`action_error` where the receiving adapter can identify a request id.

## Pairing

`baya pair` asks the resident host for a random, single-use, room-bound token.
The CLI renders a QR code and a copyable URI:

```text
remotepi://pair?t=<token>&epk=<computer-public-key>&n=<session-name>&rm=<room-id>
```

The `remotepi://` scheme remains for Android compatibility.

The mobile client sends:

```json
{"type":"pair_request","id":"request-id","token":"one-time-token","device_name":"Pixel"}
```

The host consumes the token once, verifies it belongs to this room, and saves
the authenticated sender key. It replies:

```json
{
  "type":"pair_ok",
  "in_reply_to":"request-id",
  "session_name":"Baya",
  "session_started_at":1790000000000,
  "room_id":"room-id",
  "harness":{"name":"Baya · pi","version":"2.0.0"},
  "hostname":"example"
}
```

Failures use `pair_error` with `token_expired`, `token_consumed`,
`token_unknown`, or `internal_error`.

## Sessions and rooms

The host registry stores each logical session as:

```json
{
  "id": "stable-baya-session-id",
  "name": "Review",
  "cwd": "C:\\code\\project",
  "agent": "pi",
  "created_at": 1790000000000,
  "updated_at": 1790000000000,
  "pi_session_id": "native-pi-session-id"
}
```

The room id is derived from the canonical `cwd` and a namespaced session key.
Every session has an independent host room and child-agent process.

`sessions_inventory` returns the native session keys visible to the current
adapter. A complete inventory allows the mobile client to remove stale cached
rooms; incomplete scans must not delete history.

## Chat

The mobile client sends:

```json
{
  "type":"user_message",
  "id":"stable-user-message-id",
  "text":"Review this change",
  "images":[{"data":"base64","mime":"image/jpeg"}],
  "streaming_behavior":"steer"
}
```

`images` and `streaming_behavior` are optional. The host broadcasts the same
message to every connected owner as an echo, then streams:

```json
{"type":"agent_chunk","in_reply_to":"stable-user-message-id","delta":"partial text"}
{"type":"agent_thinking","id":"stable-thinking-id","in_reply_to":"stable-user-message-id","text":"reasoning","complete":false}
{"type":"tool_request","tool_call_id":"tool-id","tool":"powershell","args":{}}
{"type":"tool_result","tool_call_id":"tool-id","result":"human-readable output"}
{"type":"agent_done","in_reply_to":"stable-user-message-id","usage":{"input_tokens":123,"output_tokens":45}}
```

There is exactly one `agent_done` per accepted turn, emitted when the adapter's
entire run settles. This remains true when tools divide a turn into multiple
assistant messages.

`cancel` aborts the current agent run and produces `cancelled`. Tool approval is
adapter-specific and arrives as an `extension_ui_request` when the underlying
agent supports interactive approval.

## History

`session_sync` requests a replay. The host emits ordered `session_history`
fragments:

```json
{
  "type":"session_history",
  "in_reply_to":"sync-id",
  "session_started_at":1790000000000,
  "events":[],
  "streaming":null,
  "eos":true,
  "truncated":false
}
```

All fragments share `in_reply_to`. Only the last has `eos: true`. The host
batches around 1 MiB of JSON and rejects a single event larger than the relay's
clean 4 MiB ceiling rather than sending an incomplete transcript.

History event types:

- `user_input`
- `agent_message`
- `agent_thinking`
- `tool_request`
- `tool_result`
- `compaction`

The final fragment carries the live stream cursor when a run is in progress,
or `streaming: null` when idle. Images are replayed inside `user_input`.

## Models, reasoning, context, and commands

The Android client can request:

```text
list_models
commands_get
context_usage_get
model_set
thinking_set
```

Responses are `models_list`, `commands_list`, `context_usage`, and
`action_ok`/`action_error`. The current model is included in `models_list` when
the adapter can identify it. Context usage contains `tokens`, `context_window`,
and `percent`.

The Pi adapter starts from Pi's documented RPC list and does not invent an SDK
extension namespace.

## Workspace and file access

Directory browsing uses:

- `workspace_browse`
- `workspace_open`

Replies are `workspace_listing`, `workspace_opened`, or `workspace_error`.
Browsing returns directories only and resolves symlinks before use.

Read-only access inside a session's `cwd` uses:

- `session_files_browse`
- `session_file_read`

Replies are `session_files_listing`, `session_file_content`, or
`session_file_error`. The host canonicalizes the session root and the requested
path and rejects paths outside the root. Listings are capped at 500 entries;
file previews are capped at 256 KiB and binaries return `content: null`.

## Interactive extension prompts

Pi and other adapters may request user input:

```json
{"type":"extension_ui_request","id":"prompt-id","method":"confirm","title":"Run command?","message":"..."}
```

Supported methods are `select`, `confirm`, `input`, `editor`, and `notify`.
The mobile responds with exactly one discriminator:

```json
{"type":"extension_ui_response","id":"prompt-id","value":"choice"}
{"type":"extension_ui_response","id":"prompt-id","confirmed":true}
{"type":"extension_ui_response","id":"prompt-id","cancelled":true}
```

The Pi adapter translates this wire shape directly to Pi's
`RpcExtensionUIResponse`. Rich extension-specific envelopes are not forwarded
to standalone Pi.

## Action lifecycle

Every action carries a unique `id`. Mutating actions return:

```json
{"type":"action_ok","in_reply_to":"request-id","action":"model_set"}
```

or:

```json
{"type":"action_error","in_reply_to":"request-id","action":"model_set","error":"..."}
```

Ordinary protocol failures use `error` with a machine-readable `code`, an
optional `in_reply_to`, and a user-readable `message`.

## Compatibility boundary

- Android application id stays `dev.wianger.remotepi`.
- Pairing URI scheme stays `remotepi://`.
- Relay message names and fields stay compatible with the existing client.
- State migration reads `~/.pi/remote` without modifying it.
- New CLI and state values use the `baya` / `BAYA_*` namespace.
