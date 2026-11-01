# Baya Relay

A small Rust WebSocket relay for Baya hosts and mobile clients. It is wire
compatible with the Remote Pi protocol defined in [../PROTOCOL.md](../PROTOCOL.md).

The relay authenticates both sides through Ed25519 challenge-response, routes
opaque encoded payload envelopes, keeps room presence, and stores signed mesh
membership metadata in SQLite. It is not an end-to-end encryption boundary:
payload envelopes are opaque to the routing code, but the relay operator
controls the TLS endpoint and executable. Self-host it for private source code.

## Run with Docker

```powershell
docker build -t baya-relay relay
docker run -d `
  --name baya-relay `
  -p 3000:3000 `
  -v baya-data:/data `
  --restart unless-stopped `
  baya-relay
```

The same port serves:

- `GET /` for the WebSocket upgrade
- `GET /health` for health checks
- `GET/POST /mesh/<owner-key-hash>` for signed membership metadata

Point Baya at the relay:

```powershell
baya set-relay http://127.0.0.1:3000
baya stop
baya start
```

Put the relay behind Caddy, nginx, or another TLS endpoint before exposing it
outside a private network, then use an `https://` or `wss://` relay URL.

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `BAYA_RELAY_PORT` | `3000` | WebSocket, health, and mesh HTTP port |
| `BAYA_MESH_DB_PATH` | `/data/mesh.db` in Docker | SQLite membership state |
| `RELAY_MAX_CT_MIB` | Implementation default | Outer-envelope byte ceiling |
| `RUST_LOG` | unset | `info`, `debug`, `warn`, or `error` logging |

`REMOTEPI_RELAY_PORT` and `REMOTEPI_MESH_DB_PATH` remain accepted as migration
aliases.

## Build and test

```powershell
cargo build --release
cargo test
cargo clippy --all-targets -- -D warnings
```
