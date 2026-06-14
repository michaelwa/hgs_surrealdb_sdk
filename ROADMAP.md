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

## Backlog (nice-to-have)

- **F1 — Telemetry instrumentation.** Emit `:telemetry` start/stop/exception
  spans around query and RPC execution (duration measurement; query / namespace /
  database metadata). Enables LiveDashboard integration and structured logging.
- **F2 — Supervised connection / config-driven repo.** Start a named SurrealDB
  connection under the host app's supervision tree from `config.exs`
  (Ecto.Repo-style) so calls no longer require passing a `client` explicitly.
  Pairs with the R2 installer, which already scaffolds the connection config.
  Note: the OTP application already validates `:connection` at boot today — this
  feature would build on that to expose a started, reusable client.

## Deferred ideas

- Make the OTP application boot gracefully when `:connection` is absent (treat
  the application-level client as opt-in). Considered during R1; deferred in
  favor of documenting the required config. Worth revisiting alongside F2.
- Migration generator task (`mix surreal_db.gen.migration`) to stamp new `.surql`
  files, complementing the existing runner.
- LiveView live-query helper: subscribe a LiveView to a `LIVE SELECT` and push
  updates into assigns.

## Publishing

- Not yet on Hex; installed as a git dependency. A Hex release is a future
  milestone once F1/F2 land and the public API stabilizes.
