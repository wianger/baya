# syntax=docker/dockerfile:1

# ── Build stage ────────────────────────────────────────────────────────────
FROM rust:1-slim-bookworm AS builder

WORKDIR /app

COPY Cargo.toml Cargo.lock ./
COPY src ./src
# Migrations are baked into the binary at compile time via `include_str!`
# (see src/mesh/store.rs). Without this COPY, `cargo build` fails inside
# the container with "couldn't read .../migrations/001_mesh_versions.sql".
COPY migrations ./migrations

RUN cargo build --release && mkdir -p /data

# ── Runtime stage ──────────────────────────────────────────────────────────
# Distroless: glibc and CA roots only — no shell, no package manager.
FROM gcr.io/distroless/cc-debian12:nonroot

COPY --from=builder /app/target/release/relay /usr/local/bin/relay
# New volumes inherit this owner, so the non-root relay can write its DB.
COPY --from=builder --chown=65532:65532 /data /data

ENV BAYA_RELAY_PORT=3000
ENV BAYA_MESH_DB_PATH=/data/mesh.db
# Mount a volume here to keep the mesh database across restarts.
VOLUME ["/data"]

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD ["/usr/local/bin/relay", "healthcheck"]

ENTRYPOINT ["/usr/local/bin/relay"]
