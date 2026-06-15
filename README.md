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
dependency and scaffold a `SurrealDB.Store` module, supervision-tree entry, and
per-app config block in one step:

```bash
mix igniter.install hgs_surrealdb_sdk --namespace app --database app
```

This adds the dep, generates a store module (see [Supervised
connection](#supervised-connection-surrealdbstore) below), wires it into your
supervision tree, and writes a per-store `config` block to
`config/runtime.exs`. Override `--endpoint`, `--namespace`, and `--database` as
needed; credentials default to `root`/`root` for a local dev server — change
them per environment in `config/runtime.exs`.

> The installer task ships behind an optional `igniter` dependency. Reaching it
> via `mix igniter.install` works out of the box. To run `mix hgs_surrealdb_sdk.install`
> directly, your project must already depend on `igniter`.

## Supervised connection (`SurrealDB.Store`)

Define a store and add it to your supervision tree to get a named, supervised,
config-driven connection — no explicit client argument on calls:

```elixir
defmodule MyApp.SurrealStore do
  use SurrealDB.Store, otp_app: :my_app
end

# config/runtime.exs
config :my_app, MyApp.SurrealStore,
  endpoint: "http://localhost:8000",
  namespace: "app",
  database: "app",
  username: "root",
  password: "root",
  transport: :http   # or :websocket

# lib/my_app/application.ex
children = [MyApp.SurrealStore]
```

```elixir
MyApp.SurrealStore.query("SELECT * FROM person")
MyApp.SurrealStore.get(MyApp.User, "user:abc")
MyApp.SurrealStore.create(MyApp.User, %{name: "Jane"})
MyApp.SurrealStore.client()   # {:ok, %SurrealDB.Client{}} escape hatch
```

Config is read when the store starts (runtime), so `config/runtime.exs` and
releases work naturally. With `transport: :websocket` the store supervises a
self-reconnecting WebSocket connection. `mix igniter.install hgs_surrealdb_sdk`
scaffolds the store module, the supervision-tree entry, and this config block
for you.

## Configuration (app-level client)

The SDK application boots without any connection config — it starts only a
Registry and waits for stores or explicit clients to be created. The block below
is needed only if you use `SurrealDB.connect/0` (the legacy app-level client
that reads a single shared connection from the SDK's own config). If you use
`SurrealDB.Store` (recommended), skip this section and configure each store
under your app's namespace instead (see above).

Add the following to `config/config.exs` if you rely on `SurrealDB.connect/0`
(override credentials per-environment in `config/runtime.exs`):

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
valid `:connection` block the call to `SurrealDB.connect/0` returns
`{:error, %SurrealDB.Error{type: :invalid_config}}`.

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

## Telemetry

The SDK emits `:telemetry` events for all query/RPC execution and WebSocket
connection lifecycle. See `SurrealDB.Telemetry` for the full event reference,
metadata field descriptions, and the metadata safety contract.

### Emitted events

- `[:surreal_db, :query, :start | :stop | :exception]` — span around every
  query, RPC, CRUD, Repo, and Store call, and around live-query start/kill.
  Covers both HTTP and WebSocket transports.
- `[:surreal_db, :connection, :connected | :disconnected | :reconnecting]` —
  discrete events from the WebSocket connection process.

### Attaching a handler

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

Or use the shipped opt-in logger, which logs each completed query (method,
namespace/database, transport, duration, and on error: `error.type` and
`error.message`):

```elixir
SurrealDB.Telemetry.attach_default_logger(level: :info)
```

### Query-text redaction

Query text is included in event metadata by default. To disable:

```elixir
config :hgs_surrealdb_sdk, :telemetry, include_query_text: false
```

When disabled, the `:query` field is replaced with `:"[redacted]"`. Variable
**values** are never emitted regardless of this setting — only keys and count.

### LiveDashboard / Telemetry.Metrics

`telemetry_metrics` is not a dependency of this SDK. In your own application's
telemetry supervisor:

```elixir
[
  Telemetry.Metrics.summary("surreal_db.query.stop.duration",
    unit: {:native, :millisecond}, tags: [:method, :namespace, :result]),
  Telemetry.Metrics.counter("surreal_db.connection.disconnected")
]
```
