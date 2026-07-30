# Senior Architect Evaluation — 2026-07-30

## Executive assessment

This repository is a strong, feature-rich SDK prototype, not yet a production-ready public Elixir SDK.

Overall assessment: **6.5/10 — credible alpha / internal production candidate**.

The project has a coherent foundation and substantially exceeds a minimal client. It includes HTTP query and CRUD APIs, a supervised `SurrealDB.Store`, Zoi-backed schemas, Repo-style persistence, WebSocket RPC, live queries, transactions, migrations, telemetry, Igniter installation, and generators.

The implementation shows good engineering judgment. The primary risk is breadth ahead of protocol confidence: most behavior is validated with adapter and fake-socket tests rather than against a real SurrealDB server.

At the time of this evaluation, `mix test` passes with **212 tests**, and formatting plus warnings-as-errors compilation pass.

## Architectural strengths

The main boundaries are sensible:

```text
Public API
  ├── SurrealDB
  ├── SurrealDB.Repo
  └── SurrealDB.Store

Protocol/RPC
  ├── SurrealDB.RPC
  ├── RPC.Request / Response
  └── Transport behaviour

Transports
  ├── HTTP
  └── WebSocket

Domain conveniences
  ├── Schema
  ├── Multi
  ├── Migrations
  └── Live queries
```

Notable strengths:

- Structured error tuples keep transport exceptions from leaking through the public API.
- RPC dispatch and telemetry are centralized.
- Identifiers are validated before SurrealQL interpolation.
- WebSockets use supervised OTP processes.
- Schema hydration is explicit and predictable.
- The low-level query API and higher-level Repo API can coexist.
- Migration checksums and failed-migration states are modeled explicitly.
- Known limitations are recorded in `ROADMAP.md` instead of being hidden.

## Highest-priority risks

### 1. No automated live-server compatibility suite

Most tests use Req adapters or fake WebSocket implementations. The file named `test/surreal_db/repo/integration_test.exs` also uses a stubbed transport.

The suite therefore validates internal behavior but not:

- Actual SurrealDB HTTP response variations
- Current WebSocket framing and setup behavior
- SurrealQL emitted by transactions
- Version-specific record, time, geometry, array, object, or custom-value semantics
- Migration behavior against a real database

This is the largest gap between a well-tested library and a dependable SDK.

### 2. WebSocket connection readiness is asynchronous but presented as synchronous

`SurrealDB.connect_ws/1` returns after starting the connection process. Sign-in and namespace/database setup happen later. A caller can immediately receive a `:websocket_connect_error` saying that the connection is not ready.

The tests work around this by waiting for setup. Ordinary consumers will not know to do that. The API should either wait for setup, queue requests until setup completes, or make the asynchronous contract explicit.

### 3. Reconnect does not restore live queries

After reconnect, the client retains local subscriptions, but the server-side live-query IDs belong to the old socket. A subscription can therefore appear active locally while receiving no events.

This is a correctness problem. The SDK should re-issue subscriptions after reconnect or mark them inactive and notify consumers.

### 4. Repo validation is inconsistent

`Repo.create/4` validates through the schema, while `Repo.update/5` passes attributes directly to SurrealDB. This conflicts with the broad README claim that invalid data returns a `ValidationError`.

The project needs an explicit update policy: full validation, partial-schema validation, or intentionally unvalidated database-side updates.

### 5. HTTP variable handling is textual substitution

`SurrealDB.Variables` performs regex replacement into query text. This is workable for a prototype but fragile: it can replace variables inside strings or comments, does not model SurrealDB-native values, and relies on JSON encoding for all compound values.

The SDK needs a deliberate value-encoding layer and, where supported, native server-side parameter binding.

### 6. Migration configuration and crash semantics need tightening

Several migration functions accept options that are not applied to registry operations, despite the documentation describing registry overrides. Migration execution and registry bookkeeping are separate requests, so a process crash can leave a migration marked `running`.

This is acceptable for an early tool but not yet equivalent to a mature migration system.

### 7. Public-library release hygiene is incomplete

The project has no visible CI workflow, changelog, supported SurrealDB version policy, or actual `LICENSE` file. Several public-facing modules also use `@moduledoc false`.

These are not the first dog-food blockers, but they will matter before external adoption or Hex publication.

## Dog-food readiness verdict

The repository is suitable for a controlled internal dog-food application if the application uses HTTP, simple JSON-compatible values, and does not depend on WebSocket live-query recovery or migration edge cases.

It is not yet suitable as a general-purpose dependency where failures must be predictable across real SurrealDB versions and connection outages.

The first phase should prioritize real-server confidence and lifecycle correctness over additional convenience features.

## Recommended delivery sequence

1. Establish a Docker-backed integration harness and supported SurrealDB version.
2. Make WebSocket readiness deterministic and test reconnect behavior.
3. Define and enforce Repo update validation.
4. Correct migration registry configuration and document crash/retry behavior.
5. Formalize HTTP value encoding and expand supported value types.
6. Add release and documentation hygiene before publishing.

The detailed, actionable backlog is maintained in `ROADMAP.md`.
