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

This SDK is not published to Hex. There are three ways to install it:

| Method | Use when |
| --- | --- |
| [Git dependency (GitHub)](#method-1--git-dependency-github) | Normal use — pull the SDK straight from the repo |
| [Local path dependency](#method-2--local-path-dependency-filesystem) | Developing the SDK and a consuming app side by side |
| [Igniter (automated)](#method-3--igniter-automated) | Your app uses Igniter and you want the dep *and* config scaffolded |

### Method 1 — Git dependency (GitHub)

Add it as a git dependency in `mix.exs`:

```elixir
def deps do
  [
    {:hgs_surrealdb_sdk, github: "michaelwa/hgs_surrealdb_sdk"}
    # pin for reproducibility:
    # {:hgs_surrealdb_sdk, github: "michaelwa/hgs_surrealdb_sdk", ref: "main"}
  ]
end
```

### Method 2 — Local path dependency (filesystem)

If you have the SDK checked out locally (e.g. to work on it and a consuming app
at the same time), point at it by path instead:

```elixir
def deps do
  [
    {:hgs_surrealdb_sdk, path: "../hgs_surrealdb_sdk"}
  ]
end
```

### Fetch and compile (Methods 1 and 2)

```bash
mix deps.get
mix deps.compile
```

> The OTP app is `:hgs_surrealdb_sdk`, but all modules live under the `SurrealDB.*` namespace.

Installing the dependency only makes the SDK *available* — it starts no
connection on its own. **Continue to [Getting started](#getting-started)** to
configure how your app connects.

### Method 3 — Igniter (automated)

If your project uses [Igniter](https://hexdocs.pm/igniter), a single command
adds the dependency *and* scaffolds the store module, supervision-tree entry,
and config — no manual `mix.exs` or config edits. See [Set up with
Igniter](#set-up-with-igniter-automated) under Getting started.

> **Note:** this SDK lists `igniter` as an *optional* dependency, so installing
> via Method 1 or 2 does **not** pull Igniter into your project.

### Troubleshooting

**Compile error mentioning `Igniter.Mix.Task.Info` and
`Mix.Tasks.PhoenixLiveView.Upgrade`** (e.g. *"expected Igniter.Mix.Task.Info to
return struct metadata, but got none"*, with a *"Please report this bug at …
elixir-lang/elixir"* footer):

This is **not** from this SDK. It is your own app's `phoenix_live_view` +
`igniter` versions hitting Elixir 1.20's type checker while compiling
`phoenix_live_view`'s Igniter-based upgrade task. Running `mix deps.compile`
recompiles those deps, which is what surfaces it. The SDK's own modules never
appear in the trace. Update the offending deps to current versions:

```bash
mix deps.update igniter phoenix_live_view
```

**App fails to boot with `missing required options` (or `missing required:
[:endpoint, :namespace, :database]`):**

A supervised store validates its config in `start_link`, so a missing or
misconfigured store **fails the application at boot** — it does not lazily error
on the first query. Two common causes:

1. The config is trapped inside the `if config_env() == :prod do ... end` block
   in `config/runtime.exs`, so it is never applied in `:dev`/`:test`. Move it
   outside that block (see [Supervised store](#supervised-store-recommended)).
2. The app atom in `config :my_app, MyApp.SurrealStore` does not match the
   `otp_app:` passed to `use SurrealDB.Store`. They must be identical.

**Git dependency does not pick up new commits:** `mix deps.get` honors the SHA
locked in `mix.lock` and will not advance on its own — even after you delete the
dep from `deps/`. To move to the latest commit on the ref, run:

```bash
mix deps.update hgs_surrealdb_sdk
```

## Getting started

The SDK application boots without any connection config: it starts only a
Registry and waits for you to create a connection. After installing, pick the
style that fits your app:

| Style | When to use | Setup |
| --- | --- | --- |
| **Supervised store** (recommended) | A long-lived, named, config-driven app connection | [Supervised store](#supervised-store-recommended) |
| **App-level client** (legacy) | A single shared connection via `SurrealDB.connect/0` | [App-level client](#app-level-client-legacy) |
| **Explicit client** | One-off scripts, tests, or multiple endpoints | Pass options straight to [`SurrealDB.connect/1`](#usage) — no config needed |

> Whichever style you choose, the target `namespace` and `database` must already
> exist on the SurrealDB server. On a fresh server, define them once (e.g. as
> `root`): `DEFINE NAMESPACE IF NOT EXISTS test;` then
> `DEFINE DATABASE IF NOT EXISTS test;` (the latter scoped to the namespace).
> See [Installing SurrealDB](docs/installing-surrealdb.md).

### Set up with Igniter (automated)

If your project uses [Igniter](https://hexdocs.pm/igniter), you can add the
dependency and scaffold a `SurrealDB.Store` module, supervision-tree entry, and
per-app config block in one step — no manual `mix.exs` or config edits needed:

```bash
mix igniter.install hgs_surrealdb_sdk --namespace app --database app
```

This adds the dep, generates a store module (see [Supervised
store](#supervised-store-recommended) below), wires it into your supervision
tree, and writes a per-store `config` block to `config/runtime.exs`. Override
`--endpoint`, `--namespace`, and `--database` as needed; credentials default to
`root`/`root` for a local dev server — change them per environment in
`config/runtime.exs`.

> The installer task ships behind an optional `igniter` dependency.
> `mix igniter.install hgs_surrealdb_sdk` fetches igniter for you and works out
> of the box. To run `mix hgs_surrealdb_sdk.install` directly instead, add
> `{:igniter, "~> 0.5", only: [:dev]}` to your deps first — without it the task
> prints installation instructions and exits.

### Supervised store (recommended)

Define a store and add it to your supervision tree to get a named, supervised,
config-driven connection — no explicit client argument on calls.

> Replace `:my_app` with your application's OTP name (the `app:` value in your
> `mix.exs`) and `MyApp` with your module prefix throughout. The app atom in
> `config :my_app, ...` **must match** the `otp_app:` you pass to
> `use SurrealDB.Store` — if they differ, the store starts with empty config and
> the application fails to boot (see [Troubleshooting](#troubleshooting)).

**1. Define the store module** (`lib/my_app/surreal_store.ex`):

```elixir
defmodule MyApp.SurrealStore do
  use SurrealDB.Store, otp_app: :my_app
end
```

**2. Add the connection config.** For static values, `config/config.exs` is the
simplest home. To drive it from environment variables (releases), use
`config/runtime.exs` — but see the warning below.

```elixir
config :my_app, MyApp.SurrealStore,
  endpoint: "http://localhost:8000",
  namespace: "app",
  database: "app",
  username: "root",
  password: "root",
  transport: :http   # or :websocket
```

> ⚠️ **Placement in `config/runtime.exs`:** a Phoenix-generated `runtime.exs`
> wraps its real configuration in an `if config_env() == :prod do ... end`
> block. This config must live **outside** that block (e.g. at the very bottom
> of the file, at the top level) — otherwise it is only applied in `:prod` and
> your app will crash at boot in `:dev`/`:test` with a `missing required
> options` error. Example using env vars:
>
> ```elixir
> # config/runtime.exs — at top level, NOT inside `if config_env() == :prod`
> config :my_app, MyApp.SurrealStore,
>   endpoint: System.get_env("SURREALDB_ENDPOINT") || "http://localhost:8000",
>   namespace: System.get_env("SURREALDB_NS") || "app",
>   database: System.get_env("SURREALDB_DB") || "app",
>   username: System.get_env("SURREALDB_USER") || "root",
>   password: System.get_env("SURREALDB_PASS") || "root",
>   transport: :http
> ```

**3. Add the store to your supervision tree** (`lib/my_app/application.ex`) —
append it to your existing `children` list, do not replace it:

```elixir
children = [
  # ... your existing children ...
  MyApp.SurrealStore
]
```

```elixir
MyApp.SurrealStore.query("SELECT * FROM person")
MyApp.SurrealStore.get(MyApp.User, "user:abc")
MyApp.SurrealStore.create(MyApp.User, %{name: "Jane"})
MyApp.SurrealStore.client()   # {:ok, %SurrealDB.Client{}} escape hatch
```

Config is read when the store starts (runtime), so `config/runtime.exs` and
releases work naturally. With `transport: :websocket` the store supervises a
self-reconnecting WebSocket connection. [`mix igniter.install
hgs_surrealdb_sdk`](#set-up-with-igniter-automated) scaffolds the store module,
the supervision-tree entry, and this config block for you.

### App-level client (legacy)

This style is needed only if you use `SurrealDB.connect/0` — the legacy
app-level client that reads a single shared connection from the SDK's own
config. If you use a [supervised store](#supervised-store-recommended)
(recommended), skip this section and configure each store under your app's
namespace instead.

Add the following to `config/config.exs` (override credentials per-environment
in `config/runtime.exs`):

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
