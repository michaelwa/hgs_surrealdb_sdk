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
- `SurrealDB.Schema` — Zoi-backed, table-bound schemas that hydrate into structs
- `SurrealDB.Repo.get/all/find/create/update/delete/query`
- basic auth or bearer token auth
- explicit anonymous mode with `anonymous: true`
- identifier validation for CRUD helpers
- JSON response parsing and structured errors
- process-backed WebSocket RPC connections with request/response matching

## Installation

> Need a SurrealDB server first? See [Installing SurrealDB](docs/installing-surrealdb.md).

This SDK is not published to Hex. Add it as a git dependency in `mix.exs`:

```elixir
def deps do
  [
    {:hgs_surrealdb_sdk, github: "michaelwa/hgs_surrealdb_sdk"}
    # pin for reproducibility:
    # {:hgs_surrealdb_sdk, github: "michaelwa/hgs_surrealdb_sdk", ref: "main"}
  ]
end
```

Then fetch it:

```bash
mix deps.get
```

> The OTP app is `:hgs_surrealdb_sdk`, but all modules live under the `SurrealDB.*` namespace.

### Install with Igniter

If your project uses [Igniter](https://hexdocs.pm/igniter), you can add the
dependency and scaffold the required connection config in one step:

```bash
mix igniter.install hgs_surrealdb_sdk --namespace app --database app
```

This adds the dep and writes a `config :hgs_surrealdb_sdk, connection: [...]`
block (see [Configuration](#configuration-required) below) to
`config/config.exs`. Override `--endpoint`, `--namespace`, and `--database` as
needed; credentials default to `root`/`root` for a local dev server — change
them per environment in `config/runtime.exs`.

> The installer task ships behind an optional `igniter` dependency. Reaching it
> via `mix igniter.install` works out of the box. To run `mix hgs_surrealdb_sdk.install`
> directly, your project must already depend on `igniter`.

## Configuration (required)

The OTP application reads connection config **at boot** and refuses to start
without it — so a host app that adds this dependency must configure it, even if
you intend to build clients at runtime with `SurrealDB.connect/1`. Add this to
`config/config.exs` (override credentials per-environment in `config/runtime.exs`):

```elixir
config :hgs_surrealdb_sdk,
  connection: [
    endpoint: "http://localhost:8000",
    namespace: "test",
    database: "test",
    # authentication — choose one:
    username: "root",
    password: "root"
    # or a bearer token:  auth_token: "..."
    # or opt out entirely: anonymous: true
  ]
```

`endpoint`, `namespace`, and `database` are required. For auth, provide
`username` **and** `password`, or `auth_token`, or `anonymous: true`. Without a
valid `:connection` block the application fails to start with
`%SurrealDB.Error{type: :invalid_config}`.

> The target `namespace` and `database` must already exist on the SurrealDB
> server. On a fresh server, define them once (e.g. as `root`):
> `DEFINE NAMESPACE IF NOT EXISTS test;` then `DEFINE DATABASE IF NOT EXISTS test;`
> (the latter scoped to the namespace). See [Installing SurrealDB](docs/installing-surrealdb.md).

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

## Schema & Repo

Define a table-backed schema with [Zoi](https://hexdocs.pm/zoi) and use `SurrealDB.Repo` for friendly, parameterized persistence that hydrates results into structs.

```elixir
defmodule MyApp.User do
  use SurrealDB.Schema

  table "user"

  schema do
    Zoi.object(%{
      id: Zoi.string() |> Zoi.optional(),
      name: Zoi.string(),
      email: Zoi.string()
    })
  end
end
```

```elixir
{:ok, client} =
  SurrealDB.connect(
    endpoint: "http://localhost:8000",
    namespace: "app",
    database: "app",
    username: "root",
    password: "root"
  )

# create -> returns a hydrated struct
{:ok, %MyApp.User{} = user} =
  SurrealDB.Repo.create(client, MyApp.User, %{name: "Jane", email: "jane@example.com"})

# fetch by record id
{:ok, %MyApp.User{}} = SurrealDB.Repo.get(client, MyApp.User, "user:abc")

# list, or filter by simple equality
{:ok, users} = SurrealDB.Repo.all(client, MyApp.User)
{:ok, %MyApp.User{}} = SurrealDB.Repo.find(client, MyApp.User, %{email: "jane@example.com"})

# update / delete
{:ok, _} = SurrealDB.Repo.update(client, MyApp.User, "user:abc", %{name: "Jane Doe"})
{:ok, _} = SurrealDB.Repo.delete(client, MyApp.User, "user:abc")
```

Invalid data returns `{:error, %SurrealDB.Schema.ValidationError{}}`; connection or query failures return `{:error, %SurrealDB.Error{}}`.

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

For a runnable example, see [examples/basic_query.exs](examples/basic_query.exs).
