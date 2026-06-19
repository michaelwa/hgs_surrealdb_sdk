# Telemetry

The SDK emits [Telemetry](https://hexdocs.pm/telemetry) events for query/RPC
execution and WebSocket connection lifecycle. See `SurrealDB.Telemetry` for the
full event reference, metadata fields, and metadata safety contract.

## Events

- `[:surreal_db, :query, :start]`
- `[:surreal_db, :query, :stop]`
- `[:surreal_db, :query, :exception]`
- `[:surreal_db, :connection, :connected]`
- `[:surreal_db, :connection, :disconnected]`
- `[:surreal_db, :connection, :reconnecting]`

Query spans cover HTTP queries, WebSocket RPC, CRUD helpers, Repo calls, Store
calls, and live-query start/kill.

## Attach a handler

```elixir
:telemetry.attach(
  "my-app-surreal-logger",
  [:surreal_db, :query, :stop],
  fn _event, measurements, metadata, _config ->
    IO.inspect({metadata.method, metadata.result, measurements.duration})
  end,
  nil
)
```

## Default logger

The shipped opt-in logger logs each completed query with method,
namespace/database, transport, duration, and error type/message when present:

```elixir
SurrealDB.Telemetry.attach_default_logger(level: :info)
```

## Query-text redaction

Query text is included in event metadata by default. To disable it:

```elixir
config :hgs_surrealdb_sdk, :telemetry, include_query_text: false
```

When disabled, the `:query` field is replaced with `:"[redacted]"`. Variable
values are never emitted, regardless of this setting. Only variable keys and
counts are emitted.

## Telemetry.Metrics

`telemetry_metrics` is not a dependency of this SDK. Add it to your application
if you want metrics:

```elixir
[
  Telemetry.Metrics.summary("surreal_db.query.stop.duration",
    unit: {:native, :millisecond},
    tags: [:method, :namespace, :result]
  ),
  Telemetry.Metrics.counter("surreal_db.connection.disconnected")
]
```
