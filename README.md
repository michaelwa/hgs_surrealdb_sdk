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

This SDK is not published to Hex yet. Install it from GitHub or a local path.

### GitHub Dependency

```elixir
def deps do
  [
    {:hgs_surrealdb_sdk, github: "michaelwa/hgs_surrealdb_sdk"}
  ]
end
```

Pin a branch, tag, or commit for reproducible builds:

```elixir
{:hgs_surrealdb_sdk, github: "michaelwa/hgs_surrealdb_sdk", ref: "main"}
```

Then fetch and compile:

```bash
mix deps.get
mix deps.compile
```

### Local Path Dependency

Use this while developing the SDK and a consuming app side by side:

```elixir
def deps do
  [
    {:hgs_surrealdb_sdk, path: "../hgs_surrealdb_sdk"}
  ]
end
```

### Igniter

If your app uses [Igniter](https://hexdocs.pm/igniter), install and scaffold a
store in one command. Because this SDK is not on Hex, include the source in the
package spec:

```bash
mix igniter.install hgs_surrealdb_sdk@github:michaelwa/hgs_surrealdb_sdk --namespace app --database app
```

For local development:

```bash
mix igniter.install hgs_surrealdb_sdk@path:../hgs_surrealdb_sdk --namespace app --database app
```

The installer adds the dependency, creates a `SurrealDB.Store` module, wires it
into your supervision tree, and writes starter config.

## Guides

- [Getting Started](docs/getting-started.md)
- [Installing SurrealDB](docs/installing-surrealdb.md)
- [Schemas and Repo](docs/schema-and-repo.md)
- [Transports and Live Queries](docs/transports-and-live-queries.md)
- [Migrations](docs/migrations.md)
- [Telemetry](docs/telemetry.md)
- [Troubleshooting](docs/troubleshooting.md)

For a small script-style example, see [examples/basic_query.exs](examples/basic_query.exs).
