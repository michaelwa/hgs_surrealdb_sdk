# HgsSurrealdbSdk

Minimal Elixir-native SurrealDB SDK for HTTP query execution.

## Status

Phase 1 currently supports:

- `SurrealDB.connect/1`
- `SurrealDB.query/2`
- basic auth or bearer token auth
- explicit anonymous mode with `anonymous: true`
- JSON response parsing and structured errors

`SurrealDB.query/3` exists to reserve the query-variables API shape, but non-empty variable maps are not implemented for the HTTP transport yet.

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

For a runnable example, see [examples/basic_query.exs](/home/michael_intandem/src/elixir_src/prototypes/hgs_surrealdb_sdk/examples/basic_query.exs).
