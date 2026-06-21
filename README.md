# HgsSurrealdbSdk

An Elixir-native SDK for [SurrealDB](https://surrealdb.com/docs/surrealdb).

It provides:

- HTTP query execution and CRUD helpers.
- A supervised `SurrealDB.Store` for app-level connections.
- `SurrealDB.Schema` structs backed by [Zoi](https://hexdocs.pm/zoi).
- `SurrealDB.Repo` helpers that validate data, write records, and hydrate
  database results back into structs.
- RPC, WebSocket, live-query, migration, and telemetry support.

The public Elixir modules live under the `SurrealDB.*` namespace. The OTP app
is `:hgs_surrealdb_sdk`.

## Demo

Define a table-backed schema with Zoi:

```elixir
defmodule MyApp.User do
  use SurrealDB.Schema

  table "user"

  schema do
    Zoi.object(%{
      id: Zoi.string() |> Zoi.optional(),
      name: Zoi.string(),
      email: Zoi.string(),
      age: Zoi.integer() |> Zoi.optional()
    })
  end
end
```

Create a supervised store:

```elixir
defmodule MyApp.SurrealStore do
  use SurrealDB.Store, otp_app: :my_app
end
```

Configure it:

```elixir
config :my_app, MyApp.SurrealStore,
  endpoint: "http://localhost:8000",
  namespace: "app",
  database: "app",
  username: "root",
  password: "root",
  transport: :http
```

Add `MyApp.SurrealStore` to your supervision tree, then use it:

```elixir
{:ok, %MyApp.User{} = user} =
  MyApp.SurrealStore.create(MyApp.User, %{
    name: "Jane",
    email: "jane@example.com",
    age: 36
  })

{:ok, %MyApp.User{} = same_user} =
  MyApp.SurrealStore.get(MyApp.User, user.id)

{:ok, [%MyApp.User{}]} =
  MyApp.SurrealStore.all(MyApp.User, %{email: "jane@example.com"})

{:ok, %MyApp.User{age: 37}} =
  MyApp.SurrealStore.update(MyApp.User, user.id, %{age: 37})

{:ok, %MyApp.User{}} =
  MyApp.SurrealStore.delete(MyApp.User, user.id)
```

Invalid data returns `{:error, %SurrealDB.Schema.ValidationError{}}`.
Connection and query failures return `{:error, %SurrealDB.Error{}}`.

## Getting Started

This SDK is not published to Hex yet. You can install it from GitHub, a local
path, or with Igniter. See the
[Getting Started guide](docs/getting-started.md#installation) for the full,
step-by-step installation instructions.

### Migrations

Create `.surql` files under `priv/surrealdb_migrations`, then use the Mix tasks
from your application:

```bash
mix surreal.gen.migration add_users
mix surreal.create --store MyApp.SurrealStore
mix surreal.setup --store MyApp.SurrealStore
mix surreal.reset --store MyApp.SurrealStore --force
mix surreal.migrate --store MyApp.SurrealStore
mix surreal.migrations --store MyApp.SurrealStore
mix surreal.rollback --store MyApp.SurrealStore --force
mix surreal.drop --store MyApp.SurrealStore --force
```

`--store` can be omitted from any of the commands above once a single
`SurrealDB.Store` is registered under `:surrealdb_stores` (e.g. via the
Igniter installer above) — the task auto-detects it.

See [Migrations](docs/migrations.md) for task options, registry behavior, and
rollback notes.

## Guides

- [Getting Started](docs/getting-started.md)
- [Installing SurrealDB](docs/installing-surrealdb.md)
- [Schemas and Repo](docs/schema-and-repo.md)
- [Transports and Live Queries](docs/transports-and-live-queries.md)
- [Migrations](docs/migrations.md)
- [Telemetry](docs/telemetry.md)
- [Troubleshooting](docs/troubleshooting.md)

For a small script-style example, see [examples/basic_query.exs](examples/basic_query.exs).
