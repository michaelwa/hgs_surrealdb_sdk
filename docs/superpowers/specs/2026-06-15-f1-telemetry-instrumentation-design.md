# F1 — Telemetry instrumentation

Date: 2026-06-15
Status: Approved design, pending implementation plan
Roadmap item: **F1 — Telemetry instrumentation**

## Goal

Emit standard `:telemetry` start/stop/exception spans around query and RPC
execution, with duration measurements and safe metadata (method, namespace,
database, transport, endpoint, query text). Add discrete connection-lifecycle
events for the WebSocket transport. The outcome enables Phoenix LiveDashboard
integration and structured logging for consumers, across both HTTP and
WebSocket transports and the F2 supervised-connection path.

## Non-goals

- Changing any return values or error shapes of the existing public API. F1 is
  purely additive instrumentation.
- Adding `telemetry_metrics`, `telemetry_poller`, or LiveDashboard as
  dependencies. LiveDashboard wiring is documented as a consumer example only.
- Row-count / result-size measurements (the `%QueryResult{}` is built above
  `RPC.call`, so it is not available at the instrumented boundary). Tracked as a
  deferred idea.
- Instrumenting the internal WebSocket setup roundtrips (signin / use ns+db).

## Execution paths (why these boundaries)

`SurrealDB.RPC.call/3` is the single chokepoint for `SurrealDB.query/2,3`,
`SurrealDB.rpc/3`, all CRUD helpers (`select`/`create`/`update`/`merge`/`patch`/
`delete`, which compile to a `"query"` RPC), the entire `SurrealDB.Repo.*`
schema layer, and all `SurrealDB.Store.*` delegators. It dispatches to
`Transport.HTTP` or `Transport.WebSocket`, and the `%Client{}` it receives
carries `transport`, `namespace`, `database`, and `endpoint`. One span here
therefore covers both transports without per-transport duplication.

Live-query `start`/`kill` bypass `RPC.call` (they roundtrip directly through
`SurrealDB.WebSocket.Connection`). They are instrumented at the
`SurrealDB.Live.start/3` and `SurrealDB.Live.kill/2` boundaries, which also hold
a `%Client{}` and do not re-enter `RPC.call` — so there is no double-counting.

Errors in this SDK are tagged tuples (`{:error, %SurrealDB.Error{}}`), not
exceptions. A failed query is therefore a normal `[:stop]` carrying the error in
metadata; `[:exception]` is reserved for genuine raises/throws/exits (e.g. a
bug, or `Req`/`Jason` raising).

## Event reference

### Execution span — `[:surreal_db, :query, …]`

Emitted via `:telemetry.span/3` at `SurrealDB.RPC.call/3`,
`SurrealDB.Live.start/3`, and `SurrealDB.Live.kill/2`.

| Event | Measurements | Notes |
|-------|--------------|-------|
| `[:surreal_db, :query, :start]` | `%{system_time, monotonic_time}` | |
| `[:surreal_db, :query, :stop]` | `%{duration, monotonic_time}` | `duration` in native units |
| `[:surreal_db, :query, :exception]` | `%{duration, monotonic_time}` | plus `:kind`, `:reason`, `:stacktrace`; re-raised |

**Start metadata:**

- `:method` — RPC method string. `"query"` for `query/2,3` and all CRUD
  helpers; the literal method for `rpc/3`; `"live"` for `Live.start/3`;
  `"kill"` for `Live.kill/2`. Always present.
- `:namespace`, `:database`, `:transport` (`:http | :websocket`), `:endpoint` —
  always present, always safe (the endpoint is the host URL; auth is carried
  separately and is never emitted).
- `:query` — the query text. **On by default.** Replaced with `:"[redacted]"`
  when `include_query_text: false` (see Configuration). Present only when a
  query string is available (`"query"`/`"live"` methods).
- `:variable_keys` — list of the variable map's keys (e.g. `[:id, :name]`).
  **Never values.**
- `:variable_count` — count of variables, when a variables map is present.
- `:params_count` — for non-`query` RPCs, the number of params (never the
  values).
- `:telemetry_span_context` — span-supplied reference correlating start↔stop↔
  exception.

**Stop metadata:** all start metadata plus —

- `:result` — `:ok | :error`.
- `:error` — `%SurrealDB.Error{} | nil`. Handlers categorize by `error.type`.
  Caveat: the struct's `raw`/`details` fields may contain response bodies
  (potential PII); the shipped default logger emits only `error.type` and
  `error.message`.

**Exception metadata:** all start metadata plus span-supplied `:kind`,
`:reason`, `:stacktrace`.

### Connection lifecycle — `[:surreal_db, :connection, …]`

Discrete events (not spans), emitted from `SurrealDB.WebSocket.Connection`, so
they cover both the F2 supervised connection and ad-hoc `SurrealDB.connect_ws/1`.
Measurement `%{system_time}` on each.

| Event | When | Extra metadata |
|-------|------|----------------|
| `[:surreal_db, :connection, :connected]` | setup completes (`setup_complete?` → true) | `:reconnect?` |
| `[:surreal_db, :connection, :disconnected]` | `{:websocket_closed, reason}` received | sanitized `:reason`, `:will_reconnect?` |
| `[:surreal_db, :connection, :reconnecting]` | a reconnect is scheduled (`Process.send_after(:reconnect, …)`) | `:backoff` |

Common metadata on all three: `:namespace`, `:database`, `:endpoint`, and
`:store` (the store module when the connection is supervised by a
`SurrealDB.Store`, otherwise `nil`).

## Configuration

```elixir
config :hgs_surrealdb_sdk, :telemetry,
  include_query_text: true   # default true
```

- `include_query_text: false` → `:query` metadata becomes `:"[redacted]"`.
- Read via `Application.get_env/3` per call (cheap; no boot-time gating, matching
  F2's runtime-config posture).
- Variable keys and counts are always emitted; variable values are never
  emitted, regardless of config.

## Consumer surface — `SurrealDB.Telemetry`

A new public module:

- **Moduledoc** — the canonical event reference (the tables above), the
  metadata-safety contract, and a LiveDashboard / `Telemetry.Metrics` example.
- **`events/0`** — returns the list of all emitted event names. Useful for
  `Telemetry.Metrics` specs and for tests.
- **`attach_default_logger/1`** — opt-in (the Ecto/Finch pattern). Attaches a
  handler that logs each completed query at a configurable level (default
  `:debug`): method, namespace/database, transport, duration; on error also
  `error.type` and `error.message`. Never logs variable values or query
  literals beyond the query text already present in metadata. Accepts
  `level:` and (optionally) whether to include query text in the log line.

Consumers may always use `:telemetry.attach/4` directly against the documented
events regardless of this helper.

## Architecture / implementation shape

- **`mix.exs`** — add `{:telemetry, "~> 1.0"}` explicitly (currently only a
  transitive dep via Req/Finch; F1 calls `:telemetry.span` directly).
- **`SurrealDB.RPC.call/3`** — wrap the existing `with` body in
  `:telemetry.span([:surreal_db, :query], start_metadata, fn -> {result,
  stop_metadata} end)`. Return value unchanged.
- **`SurrealDB.Live.start/3` and `SurrealDB.Live.kill/2`** — same span wrapper,
  with `:method` `"live"` / `"kill"`.
- **`SurrealDB.WebSocket.Connection`** — emit the three lifecycle events at the
  existing setup-complete, `{:websocket_closed, …}`, and reconnect-scheduling
  sites. Thread an optional `:store` option (defaulting to `nil`) into `State`
  for metadata.
- **`SurrealDB.Store.Supervisor`** — pass `store:` into `connection_opts` so the
  supervised connection can stamp `:store` onto its lifecycle metadata (a
  one-line F2 touch).
- **New `SurrealDB.Telemetry`** — events list, default logger, documentation.
- A small private metadata builder (shared helper or per-call-site private
  functions) centralizes the start/stop metadata construction and the
  `include_query_text` redaction so the rule lives in one place.

## Data flow

**Query/RPC (both transports):** caller → `RPC.call/3` builds `start_metadata`
from `%Client{}` + `%Request{}` → `:telemetry.span` emits `[:start]` → existing
dispatch to HTTP/WebSocket transport runs → span emits `[:stop]` with `:result`
and `:error` merged in (or `[:exception]` on raise) → original result returned
unchanged.

**Live query:** caller → `Live.start/3` / `Live.kill/2` builds metadata →
`:telemetry.span` wraps the `Connection` roundtrip → `[:stop]`/`[:exception]`.

**Connection lifecycle:** the supervised (F2) or ad-hoc `Connection` GenServer
emits a discrete event as it transitions through connected / disconnected /
reconnecting, tagged with `:store` when supervised.

## Error handling

- A transport/query failure returns `{:error, %SurrealDB.Error{}}` as today; the
  span emits `[:stop]` with `:result => :error` and the `%Error{}` in metadata.
- A raise/throw/exit inside the wrapped call emits `[:exception]` and is
  re-raised — F1 never swallows errors.
- A telemetry handler that itself raises is detached by `:telemetry` (standard
  behavior) and does not affect the query path.

## Backward compatibility

- Purely additive. No public function signature, return value, or error shape
  changes. Consumers that attach no handlers see identical behavior (the only
  cost is constructing metadata and the `:telemetry.execute` no-op dispatch).

## Testing strategy

- **Unit (HTTP):** attach a test handler; assert `[:start]`/`[:stop]` fire with
  correct measurements and metadata via the existing `Req.Test` stubs; assert
  `:result => :error` and `:error` populated on a failing call.
- **Unit (WebSocket):** drive the injectable `socket_module` fake; assert the
  same span behavior over WS, plus the three connection-lifecycle events across
  connect / close / reconnect.
- **Metadata safety:** assert variable values never appear in any emitted
  metadata; assert `include_query_text: false` redacts `:query` while keys/count
  remain.
- **Exception path:** stub the transport to raise; assert `[:exception]` with
  `:kind`/`:reason`/`:stacktrace` and that the error propagates.
- **`attach_default_logger/1`:** `ExUnit.CaptureLog` assertions for level,
  fields logged, and absence of variable values.
- **`events/0`:** assert it lists every event the code emits (guards against
  drift).

## Open questions

None outstanding — all design decisions resolved during brainstorming.
