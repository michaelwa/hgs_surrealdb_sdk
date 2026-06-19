# Getting Started

This guide covers installation and connection setup. The SDK talks to a running
[SurrealDB](https://surrealdb.com/docs/surrealdb) server; it does not bundle
one. If you need a local server first, see [Installing SurrealDB](installing-surrealdb.md).

The OTP app is `:hgs_surrealdb_sdk`, but public modules live under the
`SurrealDB.*` namespace.

## Installation

This SDK is not published to Hex. Install it from GitHub, a local path, or with
Igniter using a source-qualified package spec.

### GitHub dependency

```elixir
def deps do
  [
    {:hgs_surrealdb_sdk, github: "michaelwa/hgs_surrealdb_sdk"}
  ]
end
```

Pin a branch, tag, or commit for reproducibility:

```elixir
{:hgs_surrealdb_sdk, github: "michaelwa/hgs_surrealdb_sdk", ref: "main"}
```

Fetch and compile:

```bash
mix deps.get
mix deps.compile
```

`mix deps.get` honors the SHA locked in `mix.lock`. To move to a newer commit on
the configured ref, run:

```bash
mix deps.update hgs_surrealdb_sdk
```

### Local path dependency

If you have the SDK checked out next to your consuming app:

```elixir
def deps do
  [
    {:hgs_surrealdb_sdk, path: "../hgs_surrealdb_sdk"}
  ]
end
```

### Igniter

If your project uses [Igniter](https://hexdocs.pm/igniter), install the
dependency and scaffold a store module, supervision child, and config in one
step:

```bash
mix igniter.install hgs_surrealdb_sdk@github:michaelwa/hgs_surrealdb_sdk --namespace app --database app
```

For side-by-side local development:

```bash
mix igniter.install hgs_surrealdb_sdk@path:../hgs_surrealdb_sdk --namespace app --database app
```

The installer task ships behind an optional `igniter` dependency. Installing
with `mix igniter.install ...` fetches Igniter for you. To run the SDK task
directly instead, add this SDK and Igniter to your deps first:

```elixir
{:igniter, "~> 0.5", only: [:dev]}
```

Then run:

```bash
mix hgs_surrealdb_sdk.install --namespace app --database app
```

## Create the namespace and database

The target `namespace` and `database` must already exist on the SurrealDB
server. On a fresh server, define them once as `root`:

```sql
DEFINE NAMESPACE IF NOT EXISTS app;
DEFINE DATABASE IF NOT EXISTS app;
```

See [Installing SurrealDB](installing-surrealdb.md#create-the-namespace-and-database)
for `curl` examples.

## Supervised store

This is the recommended connection style for applications.

Define a store:

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

Add it to your supervision tree:

```elixir
children = [
  MyApp.SurrealStore
]
```

Use it without passing a client:

```elixir
MyApp.SurrealStore.query("SELECT * FROM person")
MyApp.SurrealStore.get(MyApp.User, "user:abc")
MyApp.SurrealStore.create(MyApp.User, %{name: "Jane"})
MyApp.SurrealStore.client()
```

The app atom in `config :my_app, MyApp.SurrealStore` must match the `otp_app:`
passed to `use SurrealDB.Store`. If they differ, the store starts with empty
config and the application fails at boot.

### Runtime config

A supervised store reads config when it starts, so `config/runtime.exs` works
naturally for releases:

```elixir
config :my_app, MyApp.SurrealStore,
  endpoint: System.get_env("SURREALDB_ENDPOINT") || "http://localhost:8000",
  namespace: System.get_env("SURREALDB_NS") || "app",
  database: System.get_env("SURREALDB_DB") || "app",
  username: System.get_env("SURREALDB_USER") || "root",
  password: System.get_env("SURREALDB_PASS") || "root",
  transport: :http
```

In a Phoenix-generated `runtime.exs`, put this config at top level, outside the
`if config_env() == :prod do ... end` block, unless you intentionally only want
the store configured in production.

## Verify your setup

With SurrealDB running and the namespace/database defined:

```bash
iex -S mix phx.server
# or:
iex -S mix
```

```elixir
store = MyApp.SurrealStore

store.config()
store.client()
store.query("RETURN 1 + 1")

store.query("CREATE person:alice SET name = 'Alice', age = 30")
store.query("SELECT * FROM person")
store.query("UPDATE person:alice SET age = 31")
store.query("DELETE person:alice")

store.query("CREATE person:bob SET name = $name", %{name: "Bob"})
store.query("SELECT * FROM person WHERE name = $n", %{n: "Bob"})
store.query("DELETE person:bob")
```

This verifies config placement, supervised boot, auth/transport connectivity,
read/write behavior, and variable binding.

## Explicit client

Use an explicit client for scripts, tests, or multiple endpoints:

```elixir
{:ok, client} =
  SurrealDB.connect(
    endpoint: "http://localhost:8000",
    namespace: "app",
    database: "app",
    username: "root",
    password: "root"
  )

{:ok, result} = SurrealDB.query(client, "SELECT * FROM person")
```

## App-level client

This legacy style is only needed for `SurrealDB.connect/0`, which reads one
shared connection from the SDK app config. Prefer a supervised store for new
apps.

```elixir
config :hgs_surrealdb_sdk,
  connection: [
    endpoint: "http://localhost:8000",
    namespace: "test",
    database: "test",
    username: "root",
    password: "root"
  ]
```

For auth, provide `username` and `password`, `auth_token`, or
`anonymous: true`. Without valid connection config, `SurrealDB.connect/0`
returns `{:error, %SurrealDB.Error{type: :invalid_config}}`.
