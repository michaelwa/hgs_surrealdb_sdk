# Roadmap

Living backlog for the SurrealDB Elixir SDK. Design rationale lives in
`docs/superpowers/specs/2026-06-14-backlog-and-roadmap-design.md`.

## Done

- **R1 — Dogfood install + live round-trip.** Added the SDK to a fresh Phoenix
  app and ran live connect/query/CRUD and Schema/Repo round-trips against
  SurrealDB. The documented `github:` dep compiles cleanly against `main` (no
  `ref:` needed). Key finding at the time: the OTP application required
  `config :hgs_surrealdb_sdk, connection: [...]` to boot — later superseded by
  F2, after which the app boots without it and the README documents the
  connection config under "Configuration (app-level client)".
- **R2 — Igniter installer.** `mix igniter.install hgs_surrealdb_sdk` scaffolds
  the required `config :hgs_surrealdb_sdk, connection: [...]` block via
  `Mix.Tasks.HgsSurrealdbSdk.Install`. Tested with `Igniter.Test` and verified
  live in the dogfood app.
- **R3 — Installing SurrealDB guide.** `docs/installing-surrealdb.md` covers the
  install-script, Docker, and build-from-source paths, plus the
  `DEFINE NAMESPACE/DATABASE` step a fresh server requires.
- **F2 — Supervised connection (`SurrealDB.Store`).** `use SurrealDB.Store,
  otp_app: :my_app` starts a named, supervised, config-driven connection under
  the host's supervision tree (HTTP and reconnecting WebSocket). Calls drop the
  explicit client. The SDK application now boots gracefully without
  `config :hgs_surrealdb_sdk, connection: [...]` (starting only a Registry), and
  connection config is resolved at store start (runtime) — resolving the
  deferred boot-vs-runtime tension. The installer scaffolds the store module,
  supervision child, and per-app config.
- **F1 — Telemetry instrumentation.** Emits `:telemetry` start/stop/exception
  spans under `[:surreal_db, :query, …]` around all query/RPC execution (both
  HTTP and WebSocket, including the F2 supervised path) and live-query
  start/kill, plus `[:surreal_db, :connection, …]` lifecycle events
  (connected/disconnected/reconnecting). Query text is included by default
  (redactable via `config :hgs_surrealdb_sdk, :telemetry,
  include_query_text: false`); variable values are never emitted. Ships
  `SurrealDB.Telemetry` with `events/0` and an opt-in default logger
  (`attach_default_logger/1`). Design:
  `docs/superpowers/specs/2026-06-15-f1-telemetry-instrumentation-design.md`.

## Deferred ideas

- **Exponential backoff for WebSocket reconnect.** The `Connection` process
  currently uses a fixed `reconnect_backoff` interval, so a sustained outage
  retries at a constant rate. Replace with exponential backoff (with jitter and a
  configurable cap) to reduce thundering-herd pressure during prolonged
  disconnections.
- **Re-establish live queries after WebSocket reconnect.** After a reconnect the
  `Connection` keeps its old `subscriptions` map, but the server has no record of
  those live query IDs on the new socket — subscriptions are silently orphaned.
  A follow-up should re-issue `LIVE SELECT`s (or surface a reconnect signal to
  subscribers) so live queries resume automatically.
- Migration generator task (`mix surreal_db.gen.migration`) to stamp new `.surql`
  files, complementing the existing runner.
- LiveView live-query helper: subscribe a LiveView to a `LIVE SELECT` and push
  updates into assigns.

## Publishing

- Not yet on Hex; installed as a git dependency. F1 and F2 have both landed.
  A Hex release is a future milestone once the public API stabilizes further.
