# HgsSurrealdbSdk

Minimal Elixir-native SurrealDB SDK for HTTP query execution and Phase 2 CRUD helpers.

## Status

Current support:

- `SurrealDB.connect/1`
- `SurrealDB.query/2`
- `SurrealDB.query/3`
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

For a runnable example, see [examples/basic_query.exs](/home/michael_intandem/src/elixir_src/prototypes/hgs_surrealdb_sdk/examples/basic_query.exs).
