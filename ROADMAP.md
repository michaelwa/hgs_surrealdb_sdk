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
  connection config under "Getting started → App-level client (legacy)".
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
- **gen.context generator (`mix surreal.gen.context`).** Scaffolds a context
  module, a `SurrealDB.Schema` (Zoi) module, and a timestamped `.surql` migration
  into the consuming app from a single command, mirroring `mix phx.gen.context`.
  Igniter-based with a `Mix.Task` fallback when Igniter isn't installed. Field
  syntax `name:type[?][|modifier]...` maps base types to both SurrealDB `TYPE` and
  Zoi; `?` marks optional; `|`-delimited modifiers (`readonly`/`default=`/`assert=`/
  `value=`) emit into the migration only (Zoi mirrors type + optional). User-
  supplied table identifiers are validated before reaching generated SurrealQL.
  Design: `docs/superpowers/specs/2026-06-27-surreal-gen-context-design.md`.

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
- **Distinguish initial-connect retries from true reconnects in connection
  telemetry.** F1 emits `[:surreal_db, :connection, :reconnecting]` whenever a
  (re)connection attempt is scheduled via `schedule_reconnect/1` in
  `SurrealDB.WebSocket.Connection`. That includes the *initial* connect-failure
  path in `handle_continue(:connect, …)` — so if the server is unreachable at
  startup, a consumer sees `:reconnecting` events before any `:connected` has
  ever fired. This is intentional and documented in the `SurrealDB.Telemetry`
  moduledoc, but it means a naive dashboard counting `:reconnecting` as
  "connection instability" will over-report during a cold start (e.g. the DB
  booting after the app). Two options for a follow-up: (a) suppress the event
  when `connect_count == 0` so `:reconnecting` only signals loss of an
  established connection; or (b) emit a distinct event (e.g.
  `[:surreal_db, :connection, :connect_failed]`) for pre-first-connect retries
  and reserve `:reconnecting` for true reconnects. Either is a metadata/event
  contract change, so it should land before any consumers depend on the current
  semantics. The `connect_count` field already on `State` makes (a) a one-line
  guard.
- Migration generator task (`mix surreal_db.gen.migration`) to stamp new `.surql`
  files, complementing the existing runner.
- LiveView live-query helper: subscribe a LiveView to a `LIVE SELECT` and push
  updates into assigns.

### gen.context — phase 2

Follow-ups deferred from the v1 `mix surreal.gen.context` generator (see its
design spec §10). Each is additive to the existing builder/task.

- **Unique indexes.** Let the generator emit `DEFINE INDEX` statements for unique
  constraints. Sketch: a per-field `unique` modifier (e.g. `email:string|unique`)
  emits, in the migration up-section, `DEFINE INDEX <table>_<field>_idx ON <table>
  FIELDS <field> UNIQUE;` and a matching `REMOVE INDEX <table>_<field>_idx ON
  <table>;` in the down-section; plus a `--unique a,b` option for a composite
  unique index across multiple fields (`FIELDS a, b UNIQUE`). Index-only, like the
  other modifiers — the Zoi schema is unaffected. Naming and the down-section
  `REMOVE INDEX` ordering (before `REMOVE TABLE`) are the main details to pin down.
- **Curated named validators** (`email`, `min=`, `max=`, …) that emit into *both*
  the migration `ASSERT` and a Zoi refinement — a bounded mapping table, the v2
  alternative to the v1 "raw modifiers → migration only" policy.
- **Generated context test files.** Blocked on a SurrealDB test-sandbox / cleanup
  strategy that doesn't exist yet; would otherwise be integration tests requiring a
  live DB. Pairs with a `@moduletag` opt-in approach.
- **Auto-translate SurrealQL `ASSERT`/`DEFAULT` into Zoi refinements.** Not done in
  v1 because the two validation languages don't map automatically; would need a
  recognized subset.
- **`gen.schema` / `gen.migration` composition split.** Separate sub-generators
  instead of one combined command, for finer-grained scaffolding.
- **Extend an existing context with a second schema** in one invocation (today each
  run assumes a fresh context module).
- **`belongs_to` / association-graph generation** beyond a plain `record<table>`
  field type (relationship scaffolding, graph edges).
- **Export a `.formatter.exs`** from the SDK with
  `locals_without_parens: [table: 1, schema: 1]` so generated schemas render
  `table "user"` (no parens) in host apps that `import_deps: [:hgs_surrealdb_sdk]`.
- **`pluralize/1` doubled-consonant plurals** (e.g. `quiz → quizzes`); `--plural`
  is the current escape hatch.
- **`modifier_clauses/1` micro-cleanup** — collapse the map-then-reduce into a
  single reduce (pure style).

## Publishing

- Not yet on Hex; installed as a git dependency. F1 and F2 have both landed.
  A Hex release is a future milestone once the public API stabilizes further.
