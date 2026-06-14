# HgsSurrealdbSdk

Minimal Elixir-native SurrealDB SDK for HTTP query execution, CRUD helpers, a transport-neutral RPC abstraction, and WebSocket RPC transport.

## Status

Current support:

- `SurrealDB.connect/1`
- `SurrealDB.query/2`
- `SurrealDB.query/3`
- `SurrealDB.rpc/3`
- `SurrealDB.connect_ws/1`
- `SurrealDB.live/3`
- `SurrealDB.kill/2`
- `SurrealDB.Migrations.install_registry/2`
- `SurrealDB.Migrations.install_registry!/2`
- `SurrealDB.Migrations.run/2`
- `SurrealDB.Migrations.run!/2`
- `SurrealDB.select/2`
- `SurrealDB.create/3`
- `SurrealDB.update/3`
- `SurrealDB.merge/3`
- `SurrealDB.patch/3`
- `SurrealDB.delete/2`
- basic auth or bearer token auth
- explicit anonymous mode with `anonymous: true`
- identifier validation for CRUD helpers
- JSON response parsing and structured errors
- process-backed WebSocket RPC connections with request/response matching

## Installation

Add the dependency in `mix.exs`:

```elixir
def deps do
  [
    {:hgs_surrealdb_sdk, "~> 0.1.0"}
  ]
end
```

## Usage

```elixir
{:ok, client} =
  SurrealDB.connect(
    endpoint: "http://localhost:8000",
    namespace: "test",
    database: "test",
    username: "root",
    password: "root"
  )

{:ok, result} = SurrealDB.query(client, "SELECT * FROM person")

IO.inspect(result.results)
```

## CRUD

```elixir
{:ok, _} = SurrealDB.create(client, "person", %{name: "Jane"})
{:ok, people} = SurrealDB.select(client, "person")
{:ok, _} = SurrealDB.merge(client, "person:jane", %{active: true})
{:ok, _} = SurrealDB.delete(client, "person:jane")

IO.inspect(people.results)
```

## RPC

```elixir
{:ok, response} = SurrealDB.rpc(client, "query", ["SELECT * FROM person"])

IO.inspect(response.result)
```

## WebSocket

```elixir
{:ok, conn} =
  SurrealDB.connect_ws(
    endpoint: "ws://localhost:8000/rpc",
    namespace: "test",
    database: "test",
    username: "root",
    password: "root"
  )

{:ok, result} = SurrealDB.query(conn, "SELECT * FROM person")

IO.inspect(result.results)
```

The WebSocket transport uses `WebSockex` because it is a maintained Elixir WebSocket client with recent releases and an OTP-friendly process model, which fits the SDK's connection-process design.

## Live Queries

```elixir
{:ok, conn} =
  SurrealDB.connect_ws(
    endpoint: "ws://localhost:8000/rpc",
    namespace: "test",
    database: "test",
    username: "root",
    password: "root"
  )

{:ok, subscription} =
  SurrealDB.live(conn, "LIVE SELECT * FROM person", send_to: self())

receive do
  {:surrealdb_live, "live-person", event} ->
    IO.inspect(event)
end

:ok = SurrealDB.kill(conn, subscription)
```

Live queries use the message API. The query should be passed explicitly as `LIVE SELECT ...`; the SDK does not rewrite a normal `SELECT` into a live query automatically.

## Migrations

```elixir
:ok = SurrealDB.Migrations.install_registry(client)

{:ok, results} =
  SurrealDB.Migrations.run(
    client,
    path: "priv/surrealdb_migrations/app",
    target_ns: "app_ns",
    target_db: "app_db",
    sdk_version: "0.1.0"
  )

IO.inspect(results)
```

The migration runner scans `.surql` files, applies them in lexicographic filename order, and records state in the SDK registry table `sdk_migration`. The default registry location is namespace `sdk_meta` and database `migration_registry`; pass `registry_ns:` and `registry_db:` to override it.

Feature 1 supports HTTP clients. WebSocket clients return a structured unsupported-client error because WebSocket namespace/database scope is established when the connection starts.

For a runnable example, see [examples/basic_query.exs](/home/michael_intandem/src/elixir_src/prototypes/hgs_surrealdb_sdk/examples/basic_query.exs).
