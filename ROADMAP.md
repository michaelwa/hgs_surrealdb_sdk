# Roadmap

Living backlog for the SurrealDB Elixir SDK. Design rationale lives in
`docs/superpowers/specs/2026-06-14-backlog-and-roadmap-design.md`.

## Dog-food priority backlog

These items are ordered by value for an application using the SDK now. They
are intentionally ahead of new convenience features: dog-food value depends
first on proving protocol compatibility, deterministic connection behavior,
and consistent data contracts.

### P0 — Deterministic WebSocket readiness (completed 2026-07-30)

**Status:** Complete. Direct WebSocket connections now wait for authentication
and namespace/database setup under one overall timeout; supervised stores retain
asynchronous reconnect behavior. Coverage includes fake-socket and real-server
integration tests, and the transport guide documents the contract.

**Problem:** `SurrealDB.connect_ws/1` returns before signin and namespace/
database setup completes. Immediate calls can fail with "connection not ready".

**Outcome:** Define one clear contract. Recommended: `connect_ws/1` waits for
initial setup until the configured timeout and returns an error if setup fails;
supervised stores may continue to reconnect asynchronously after startup.

**Acceptance criteria:**

- A successful `connect_ws/1` client can issue its first query immediately.
- Authentication and `USE` failures are returned from `connect_ws/1`.
- Startup timeout behavior is documented and tested.
- Store startup remains compatible with supervisor-driven reconnect behavior.
- Tests no longer need an undocumented `wait_for_setup/0` helper for normal
  client usage.

**Likely scope:** `SurrealDB.connect_ws/1`, `SurrealDB.WebSocket`,
`SurrealDB.WebSocket.Connection`, fake socket tests, and transport docs.

### P0 — WebSocket reconnect and live-query recovery

**Problem:** Reconnect retains local subscriptions, but the server loses the
old live-query registrations. Subscriptions can look active while silently
orphaned.

**Outcome:** Re-register active live queries after a successful reconnect, or
explicitly mark them disconnected and notify subscribers. Re-registration is
the preferred dog-food behavior.

**Acceptance criteria:**

- A live query receives events before and after a socket reconnect.
- A failed re-registration produces a visible event or structured error.
- Subscription identity semantics are documented when the server assigns a
  new ID.
- Pending RPC callers are still failed exactly once on disconnect.
- Reconnect tests cover setup failure, successful recovery, and repeated
  outages.

**Likely scope:** WebSocket connection state, subscription model, telemetry,
fake socket tests, and the live-query guide.

### P1 — Consistent Repo update validation

**Problem:** `Repo.create/4` validates attributes, while `Repo.update/5` does
not. The README implies a broader validation guarantee than the implementation
provides.

**Outcome:** Adopt partial-schema validation for updates: validate supplied
fields against the schema, preserve omitted fields, and reject unknown or
invalid values before network dispatch. Document an explicit escape hatch for
raw database-side updates if needed.

**Acceptance criteria:**

- Invalid update values return `SurrealDB.Schema.ValidationError` without a
  network request.
- Optional fields and omitted fields remain compatible with partial updates.
- Unknown fields follow one documented policy and are tested.
- `Multi.update` uses the same validation policy as `Repo.update`.
- README and schema documentation match the behavior.

**Likely scope:** `SurrealDB.Schema`, `SurrealDB.Repo.Statement`, `Repo`,
`Multi`, and their tests/docs.

### P1 — Migration registry correctness and recovery policy

**Problem:** Registry-related options are accepted but not consistently
applied. Migration execution and registry bookkeeping are separate requests,
so a crash can leave a migration in `running`.

**Outcome:** Make registry namespace/database configuration effective in every
migration operation, then document and test the failure model. Add an explicit
operator policy for stale `running` rows rather than silently guessing.

**Acceptance criteria:**

- `registry_ns` and `registry_db` affect install, status, run, reset, and
  rollback consistently.
- A migration run against a separate registry database is covered by a live
  integration test.
- Stale `running` rows have a documented recovery command or option.
- Concurrent runners cannot both execute the same migration successfully.
- The CLI and Elixir API expose the same option names and semantics.

**Likely scope:** `SurrealDB.Migrations`, migration task helpers, registry
schema, migration tests, CLI docs, and integration tests.

### P1 — SurrealDB value encoding contract

**Problem:** HTTP variables are interpolated textually and encoded mostly as
JSON. This does not provide a stable contract for SurrealDB-native values and
can replace matching variable text inside quoted strings or comments.

**Outcome:** Introduce a tested encoder boundary for query values. Preserve
safe literal generation for current JSON-compatible values and explicitly add
or reject native types such as record IDs and datetimes.

**Acceptance criteria:**

- Variable replacement cannot alter quoted strings or comments.
- Strings, booleans, numbers, nulls, lists, and maps have deterministic tests.
- Unsupported values return structured errors rather than raising.
- Native SurrealDB values have documented representations or explicit
  unsupported errors.
- The encoder is shared by Repo, Multi, migrations, and raw queries.

**Likely scope:** `SurrealDB.Variables`, RPC/HTTP transport tests, value types,
and query documentation.

### P2 — Production observability and failure semantics

**Problem:** Telemetry exists, but WebSocket lifecycle semantics and retry
behavior are not yet sufficient for reliable operational diagnosis.

**Outcome:** Stabilize telemetry event names and metadata, distinguish initial
connect failure from reconnect after an established connection, and add
bounded exponential backoff with jitter.

**Acceptance criteria:**

- Initial connection failure and post-connect disconnect are distinguishable.
- Retry delays are bounded, configurable, and tested without real sleeps.
- Sensitive credentials and variable values never appear in telemetry or
  default logs.
- Connection and subscription recovery events are documented.

**Likely scope:** WebSocket connection state, `SurrealDB.Telemetry`, config,
and telemetry tests/docs.

### P2 — Public API and release hygiene

**Problem:** The project is not yet ready for broad external adoption: public
modules are under-documented, there is no visible CI/release workflow, and the
repository lacks a changelog and license file.

**Outcome:** Make the package self-explanatory and publishable after the P0/P1
reliability work is complete.

**Acceptance criteria:**

- All supported public modules have meaningful moduledocs and specs.
- CI runs formatting, compilation, unit tests, and integration tests where
  available.
- A real MIT `LICENSE` file and changelog exist.
- Supported Elixir and SurrealDB versions are documented.
- `mix hex.build` succeeds with the intended files and metadata.

**Likely scope:** `mix.exs`, public modules, `README.md`, `docs/`, CI files,
`LICENSE`, and `CHANGELOG.md`.

## Secondary feature backlog

The following items remain useful, but should follow the reliability work
above when the goal is dog-fooding the current library:

## Done

- **P0 — Deterministic WebSocket readiness (2026-07-30).** Direct
  `connect_ws/1` now waits for authentication and namespace/database setup under
  one overall timeout, returns setup failures, and permits an immediate first
  query. Supervised stores retain asynchronous reconnect behavior. Unit and
  pinned-server integration coverage pass, and readiness polling was removed.

- **P0 — Real SurrealDB integration harness (2026-07-30).** Completed with
  pinned `surrealdb/surrealdb:v3.1.5`, localhost-only Compose lifecycle on
  port `18000`, failure-log collection, endpoint safety checks, and opt-in
  `@moduletag :integration` coverage for HTTP, Repo, transactions, migrations,
  WebSocket RPC, live-query events, and disconnect telemetry. Verified locally
  with `./scripts/test-integration`; ordinary `mix test` remains Docker-free.
  CI runs the same runner in a separate integration job.

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
- **First-class transactions (`Store.transaction/1` + `SurrealDB.Multi`).**
  Adds an `Ecto.Multi`-style builder and runner for composing typed,
  Zoi-validated CRUD steps plus raw SurrealQL into one atomic
  `BEGIN/COMMIT` block. `SurrealDB.transaction/2` maps server rollback errors
  back to step names when the failing statement index is available, and
  `Store.transaction/1` exposes the same contract from supervised stores.
  Design: `docs/superpowers/specs/2026-07-03-transactions-multi-design.md`.

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

- **timestamps() helper functions** add helper functions that will add created_at, and updated_at colums to zoi schema, and migration fields
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
