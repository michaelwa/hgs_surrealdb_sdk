# F2 — Supervised, config-driven SurrealDB connection (`SurrealDB.Store`)

Date: 2026-06-14
Status: Approved design, pending implementation plan
Roadmap item: **F2 — Supervised connection / config-driven repo**

## Goal

Let a host app start a named SurrealDB connection under its own supervision tree
from config (Ecto.Repo-style), so calls no longer require passing a `%SurrealDB.Client{}`
explicitly. As a paired outcome, resolve the roadmap's deferred boot-vs-runtime
`:connection` tension: the SDK's own OTP application should boot gracefully without
`config :hgs_surrealdb_sdk, connection: [...]`, and connection config should be
read at runtime (when the host's child starts) rather than gated at SDK boot.

## Non-goals

- Replacing or changing the existing low-level, client-arg modules
  (`SurrealDB.query/3`, `SurrealDB.Repo.get/3`, etc.). They remain as-is.
- A Hex release (tracked separately on the roadmap).
- Connection pooling beyond what `Req`/Finch already provide for HTTP.

## Programming model

Host defines a store module and adds it to its supervision tree:

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

# application supervision tree
children = [MyApp.SurrealStore]
```

Usage carries no explicit client:

```elixir
MyApp.SurrealStore.query("SELECT * FROM person", %{})
MyApp.SurrealStore.get(MyApp.User, "user:abc")      # schema-CRUD via SurrealDB.Repo
MyApp.SurrealStore.all(MyApp.User, %{active: true})
MyApp.SurrealStore.create(MyApp.User, %{...})
MyApp.SurrealStore.live("LIVE SELECT ...")           # websocket only
MyApp.SurrealStore.client()                           # escape hatch → resolved %Client{}
```

### Generated surface

The `use SurrealDB.Store` macro injects, on the host module:

- Lifecycle: `child_spec/1`, `start_link/1`, `config/0`, `client/0`.
- Raw API (delegating to `SurrealDB.*`, client arg removed): `query/1,2`,
  `rpc/3`, `live/1,2`, `kill/1`.
- Schema-CRUD (delegating to `SurrealDB.Repo.*`, client arg removed):
  `get/2,3`, `all/1,2,3`, `find/2,3`, `create/2,3`, `update/3,4`, `delete/2,3`,
  and schema `query/3,4`.

**Naming-collision decision:** the raw thing-string helpers
(`SurrealDB.select/create/update/merge/patch/delete(thing, data)`) collide on
names with the schema-CRUD functions. The Store surfaces the **schema-CRUD**
versions and does **not** surface the raw thing-string helpers. For raw record
access, callers use `query/2` or `client()` + the `SurrealDB.*` functions
directly.

Each delegator resolves the live client (see "Client resolution") and then
calls the existing `SurrealDB.*` / `SurrealDB.Repo.*` function. No business
logic is duplicated.

## Architecture

### New modules

- **`SurrealDB.Store`** — the `__using__` macro. Injects the lifecycle and
  delegating functions described above.
- **`SurrealDB.Store.Supervisor`** — one per store module. At start it resolves
  config, validates it, publishes the resolved client, and (for WebSocket)
  supervises the live connection.
- **`SurrealDB.Store.Server`** — a lightweight GenServer per store that resolves
  + validates config at init and publishes the static resolved `%Client{}` to
  `:persistent_term`. For HTTP it owns nothing further; for WebSocket it sits
  alongside the supervised `Connection`.

### SDK OTP application change

`HgsSurrealdbSdk.Application.start/2` changes from "validate `:connection` or
refuse to boot" to starting exactly one child:

```elixir
children = [{Registry, keys: :unique, name: SurrealDB.Store.Registry}]
```

It boots regardless of whether any connection config is present. This resolves
the deferred "boot gracefully when `:connection` is absent" idea and provides
the registry infrastructure stores depend on.

### Config resolution and precedence

When a store's `Supervisor` starts, it merges config from two sources and
validates the result via the **existing `SurrealDB.Config.build_client/1`**
(reused — no new validation logic):

1. `Application.get_env(otp_app, store_module)` (the app env).
2. Inline opts passed to `use SurrealDB.Store` / `child_spec/1` / `start_link/1`.

**Precedence:** inline opts override app env (matches Ecto's `:start` opts
behavior; lets tests and per-start overrides win). Resolution runs at child
start = runtime, so `runtime.exs` values are available in releases.

### Client resolution at call time

Split by what changes:

- The **static resolved `%Client{}`** is written once at store start to
  `:persistent_term` under the key `{SurrealDB.Store, store_module}`. Reads are
  lock-free and concurrent — suited to the hot query path.
- For **WebSocket**, the live `SurrealDB.WebSocket.Connection` pid changes across
  reconnects, so the `Connection` registers itself in `SurrealDB.Store.Registry`
  under `store_module`. Resolution does a `Registry.lookup` and stamps
  `connection: pid` onto the static client.

```
HTTP store:  client() = persistent_term.get({SurrealDB.Store, Mod})
WS store:    client() = %Client{static | connection: <Registry.lookup(Mod) pid>}
```

Rejected alternative: routing every call through `GenServer.call` to the Server,
which would serialize the hot path. persistent_term + Registry keeps reads
concurrent.

### Supervision shape per transport

- **HTTP**: `Store.Supervisor` → `Store.Server` only. `Store.Server` resolves +
  validates config and publishes the client to persistent_term. HTTP is
  stateless via `Req`, so nothing else is owned.
- **WebSocket**: `Store.Supervisor` (`:one_for_one`) → `Store.Server` +
  `SurrealDB.WebSocket.Connection`, now supervised with restart/backoff (today
  the `Connection` is started unsupervised by the caller). On each (re)connect
  the `Connection` re-registers its pid in `SurrealDB.Store.Registry`, so
  resolution always finds the current socket.

## Data flow

**Boot:** host tree starts `MyApp.SurrealStore` → `Store.Supervisor.start_link`
→ merge `Application.get_env(:my_app, MyApp.SurrealStore)` with inline opts →
`SurrealDB.Config.build_client/1` validates → on success `persistent_term.put`
the static client. HTTP: done. WebSocket: also start the supervised `Connection`;
on connect it registers its pid in the Registry.

**Call:** `MyApp.SurrealStore.query(surql, vars)` → resolve client
(persistent_term, plus Registry lookup for WS) → `SurrealDB.query(client, surql, vars)`.

## Error handling

- **Invalid config at start** → `Store.Supervisor` start fails with
  `{:error, %SurrealDB.Error{type: :invalid_config}}`, crashing host boot with a
  clear message (Ecto-style fail-fast). Correct because config is read at
  runtime where `runtime.exs` values exist.
- **Call before the store is started** → persistent_term miss →
  `{:error, %SurrealDB.Error{type: :not_started}}`.
- **WebSocket not connected / down** → resolution returns
  `{:error, %SurrealDB.Error{type: :not_connected}}`; otherwise existing
  `:websocket_closed` / `:websocket_timeout` errors flow through. The Supervisor
  restarts `Connection` with backoff; the static client in persistent_term is
  unaffected.

## Backward compatibility

- The existing `SurrealDB.Repo` (client-arg schema-CRUD) and all `SurrealDB.*`
  functions are unchanged.
- `SurrealDB.connect/0` still lazily reads `config :hgs_surrealdb_sdk, connection:`
  — unchanged behavior, just no longer validated at SDK boot.
- README "Configuration (required)" is reframed: required *for the app-level
  client*, not for booting the SDK application.

## Installer (R2) update

`mix hgs_surrealdb_sdk.install` (Igniter task) is updated to:

1. Generate `MyApp.SurrealStore` (`use SurrealDB.Store, otp_app: :my_app`).
2. Add it to the host supervision tree
   (`Igniter.Project.Application.add_new_child`).
3. Write `config :my_app, MyApp.SurrealStore, [...]` instead of
   `config :hgs_surrealdb_sdk, connection: [...]`.

## Testing strategy

- **Unit:** macro expansion against a fixture store module; config merge
  precedence (inline opts override app env); persistent_term publish; resolution
  errors (`:not_started`, `:not_connected`).
- **HTTP:** `Store.query` via the existing `Req.Test`/stub patterns from
  `test/surreal_db/http_test.exs`.
- **WebSocket:** Store using the existing injectable `socket_module` fake →
  supervised start, Registry registration, query round-trip, and reconnect
  re-registering the pid.
- **Integration:** live round-trip, tagged like
  `test/surreal_db/repo/integration_test.exs`.

## Open questions

None outstanding — all design decisions resolved during brainstorming.
