# Roadmap

Living backlog for the SurrealDB Elixir SDK. Design rationale lives in
`docs/superpowers/specs/2026-06-14-backlog-and-roadmap-design.md`.

## Done

- **R1 — Dogfood install + live round-trip.** Added the SDK to a fresh Phoenix
  app and ran live connect/query/CRUD and Schema/Repo round-trips against
  SurrealDB. The documented `github:` dep compiles cleanly against `main` (no
  `ref:` needed). Key finding: the OTP application refuses to boot without
  `config :hgs_surrealdb_sdk, connection: [...]`, which now has a dedicated
  "Configuration (required)" section in the README.
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

## Backlog (nice-to-have)

- **F1 — Telemetry instrumentation.** Emit `:telemetry` start/stop/exception
  spans around query and RPC execution (duration measurement; query / namespace /
  database metadata). Enables LiveDashboard integration and structured logging.

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

- Not yet on Hex; installed as a git dependency. A Hex release is a future
  milestone once F1/F2 land and the public API stabilizes.
