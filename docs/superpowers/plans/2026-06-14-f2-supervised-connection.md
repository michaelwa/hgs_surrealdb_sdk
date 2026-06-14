# F2 — Supervised SurrealDB Connection (`SurrealDB.Store`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an Ecto-style `use SurrealDB.Store, otp_app: :my_app` macro that starts a named, supervised, config-driven SurrealDB connection so callers stop passing an explicit `%SurrealDB.Client{}`.

**Architecture:** The SDK's OTP app boots gracefully and starts only a `Registry`. A host store module's supervisor resolves + validates config at child start (runtime), publishes the static resolved `%Client{}` to `:persistent_term`, and (for WebSocket) supervises a self-reconnecting `WebSocket.Connection` registered by store module. Generated delegators resolve the live client and call the existing `SurrealDB.*` / `SurrealDB.Repo.*` functions — no business logic is duplicated.

**Tech Stack:** Elixir, OTP (Supervisor/GenServer/Registry/`:persistent_term`), Req (HTTP), websockex (WS), ExUnit, Igniter (installer).

Design spec: `docs/superpowers/specs/2026-06-14-f2-supervised-connection-design.md`

---

## File Structure

- Create: `lib/surreal_db/store.ex` — the `use SurrealDB.Store` macro + runtime resolution helpers (`fetch_client/1`, `client/1`, `config/2`).
- Create: `lib/surreal_db/store/supervisor.ex` — per-store supervisor: config merge/validate, child layout per transport.
- Create: `lib/surreal_db/store/server.ex` — per-store GenServer owning the `:persistent_term` lifecycle.
- Modify: `lib/hgs_surrealdb_sdk/application.ex` — boot gracefully; start `SurrealDB.Store.Registry`.
- Modify: `lib/surreal_db/error.ex` — add `not_started/1`, `not_connected/1` constructors.
- Modify: `lib/surreal_db/web_socket/connection.ex` — support `:name` and opt-in `:reconnect` (with backoff).
- Modify: `lib/mix/tasks/hgs_surrealdb_sdk.install.ex` — scaffold the store module + supervision-tree child + per-app config.
- Modify: `README.md`, `ROADMAP.md` — document the Store; move F2 to Done.
- Test: `test/surreal_db/store_test.exs`, `test/surreal_db/store/supervisor_test.exs`, `test/hgs_surrealdb_sdk/application_test.exs`, and additions to `test/surreal_db/web_socket_test.exs`, `test/mix/tasks/hgs_surrealdb_sdk_install_test.exs`.

Conventions to follow (observed in the codebase):
- All public functions return `{:ok, _}` / `{:error, %SurrealDB.Error{}}`.
- Tests use `use ExUnit.Case, async: true` where no global state is shared. Tasks touching `:persistent_term`/the shared `Registry`/`Application.put_env` MUST use `async: false`.
- WS tests use the injectable `FakeSocket` (see `test/surreal_db/web_socket_test.exs`) via `socket_module:` and a client `request_options: [test_pid:, auto_setup:]`.

---

## Task 1: Graceful boot + `SurrealDB.Store.Registry`

**Files:**
- Modify: `lib/hgs_surrealdb_sdk/application.ex`
- Test: `test/hgs_surrealdb_sdk/application_test.exs` (create)

- [ ] **Step 1: Write the failing test**

Create `test/hgs_surrealdb_sdk/application_test.exs`:

```elixir
defmodule HgsSurrealdbSdk.ApplicationTest do
  use ExUnit.Case, async: true

  test "the store registry is started and empty by default" do
    assert is_pid(Process.whereis(SurrealDB.Store.Registry))
    assert Registry.lookup(SurrealDB.Store.Registry, :missing_store) == []
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/hgs_surrealdb_sdk/application_test.exs`
Expected: FAIL — `Process.whereis(SurrealDB.Store.Registry)` returns `nil`.

- [ ] **Step 3: Implement graceful boot + registry**

Replace the body of `lib/hgs_surrealdb_sdk/application.ex`:

```elixir
defmodule HgsSurrealdbSdk.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: SurrealDB.Store.Registry}
    ]

    opts = [strategy: :one_for_one, name: HgsSurrealdbSdk.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

The SDK app no longer calls `SurrealDB.Config.build_application_client/0` at boot, so it boots whether or not `config :hgs_surrealdb_sdk, connection: [...]` is present. `SurrealDB.Config` and `SurrealDB.connect/0` are unchanged and keep working lazily.

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/hgs_surrealdb_sdk/application_test.exs test/surreal_db/config_test.exs`
Expected: PASS (config tests still pass; build_application_client is still callable, just not at boot).

- [ ] **Step 5: Commit**

```bash
git add lib/hgs_surrealdb_sdk/application.ex test/hgs_surrealdb_sdk/application_test.exs
git commit -m "feat: boot SDK app gracefully and start Store registry"
```

---

## Task 2: Error constructors `not_started/1` and `not_connected/1`

**Files:**
- Modify: `lib/surreal_db/error.ex`
- Test: `test/surreal_db/error_test.exs` (create)

- [ ] **Step 1: Write the failing test**

Create `test/surreal_db/error_test.exs`:

```elixir
defmodule SurrealDB.ErrorTest do
  use ExUnit.Case, async: true

  alias SurrealDB.Error

  test "not_started/1 builds a typed error" do
    error = Error.not_started(MyApp.Store)
    assert %Error{type: :not_started, details: %{store: MyApp.Store}} = error
    assert error.message =~ "not started"
  end

  test "not_connected/1 builds a typed error" do
    error = Error.not_connected(MyApp.Store)
    assert %Error{type: :not_connected, details: %{store: MyApp.Store}} = error
    assert error.message =~ "not connected"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/surreal_db/error_test.exs`
Expected: FAIL — `function Error.not_started/1 is undefined`.

- [ ] **Step 3: Implement the constructors**

Add to `lib/surreal_db/error.ex`, right after the `invalid_config/2` function (before `http_error/2`):

```elixir
  @spec not_started(module()) :: t()
  def not_started(store) do
    %__MODULE__{
      type: :not_started,
      message: "store #{inspect(store)} is not started — add it to your supervision tree",
      details: %{store: store}
    }
  end

  @spec not_connected(module()) :: t()
  def not_connected(store) do
    %__MODULE__{
      type: :not_connected,
      message: "store #{inspect(store)} is not connected",
      details: %{store: store}
    }
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/surreal_db/error_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/surreal_db/error.ex test/surreal_db/error_test.exs
git commit -m "feat: add not_started/not_connected error constructors"
```

---

## Task 3: `SurrealDB.Store.Server` — persistent_term lifecycle

**Files:**
- Create: `lib/surreal_db/store/server.ex`
- Test: `test/surreal_db/store/server_test.exs` (create)

The Server is started by a store's supervisor with the already-resolved `%Client{}`. On init it publishes the client to `:persistent_term`; on terminate it erases it. The persistent_term key is `{SurrealDB.Store, store_module}`.

- [ ] **Step 1: Write the failing test**

Create `test/surreal_db/store/server_test.exs`:

```elixir
defmodule SurrealDB.Store.ServerTest do
  use ExUnit.Case, async: false

  alias SurrealDB.Client
  alias SurrealDB.Store.Server

  defmodule FakeStore do
  end

  setup do
    on_exit(fn -> :persistent_term.erase({SurrealDB.Store, FakeStore}) end)
    :ok
  end

  test "publishes the client to persistent_term on start and erases on stop" do
    client = %Client{endpoint: "http://localhost:8000", namespace: "ns", database: "db"}

    {:ok, pid} = Server.start_link({FakeStore, client})

    assert :persistent_term.get({SurrealDB.Store, FakeStore}) == client

    ref = Process.monitor(pid)
    GenServer.stop(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}

    assert :persistent_term.get({SurrealDB.Store, FakeStore}, :missing) == :missing
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/surreal_db/store/server_test.exs`
Expected: FAIL — `SurrealDB.Store.Server` is undefined.

- [ ] **Step 3: Implement the Server**

Create `lib/surreal_db/store/server.ex`:

```elixir
defmodule SurrealDB.Store.Server do
  @moduledoc false

  use GenServer

  alias SurrealDB.Client

  @spec start_link({module(), Client.t()}) :: GenServer.on_start()
  def start_link({store, %Client{} = client}) when is_atom(store) do
    GenServer.start_link(__MODULE__, {store, client})
  end

  @impl true
  def init({store, %Client{} = client}) do
    :persistent_term.put({SurrealDB.Store, store}, client)
    Process.flag(:trap_exit, true)
    {:ok, %{store: store}}
  end

  @impl true
  def terminate(_reason, %{store: store}) do
    :persistent_term.erase({SurrealDB.Store, store})
    :ok
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/surreal_db/store/server_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/surreal_db/store/server.ex test/surreal_db/store/server_test.exs
git commit -m "feat: add Store.Server owning persistent_term client lifecycle"
```

---

## Task 4: `SurrealDB.Store.Supervisor` — config resolution, validation, HTTP children

**Files:**
- Create: `lib/surreal_db/store/supervisor.ex`
- Test: `test/surreal_db/store/supervisor_test.exs` (create)

Resolves config by merging `Application.get_env(otp_app, store)` with inline opts (inline wins), validates via the existing `SurrealDB.Config.build_client/1`, and starts children. This task implements the HTTP path (children = `[Server]`). The WebSocket child is added in Task 7.

- [ ] **Step 1: Write the failing test**

Create `test/surreal_db/store/supervisor_test.exs`:

```elixir
defmodule SurrealDB.Store.SupervisorTest do
  use ExUnit.Case, async: false

  alias SurrealDB.Client
  alias SurrealDB.Error
  alias SurrealDB.Store.Supervisor, as: StoreSupervisor

  defmodule HttpStore do
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:store_sup_test, HttpStore)
      :persistent_term.erase({SurrealDB.Store, HttpStore})
    end)

    :ok
  end

  test "resolves app env, publishes a validated client, starts supervised" do
    Application.put_env(:store_sup_test, HttpStore,
      endpoint: "http://localhost:8000",
      namespace: "ns",
      database: "db",
      username: "root",
      password: "root"
    )

    assert {:ok, pid} = StoreSupervisor.start_link(HttpStore, :store_sup_test, [])
    assert is_pid(pid)

    client = :persistent_term.get({SurrealDB.Store, HttpStore})
    assert %Client{endpoint: "http://localhost:8000", namespace: "ns", transport: :http} = client

    Supervisor.stop(pid)
  end

  test "inline opts override app env" do
    Application.put_env(:store_sup_test, HttpStore,
      endpoint: "http://localhost:8000",
      namespace: "ns",
      database: "db",
      username: "root",
      password: "root"
    )

    assert {:ok, pid} =
             StoreSupervisor.start_link(HttpStore, :store_sup_test, namespace: "override")

    assert %Client{namespace: "override"} = :persistent_term.get({SurrealDB.Store, HttpStore})

    Supervisor.stop(pid)
  end

  test "invalid config returns a structured error and does not start" do
    Application.put_env(:store_sup_test, HttpStore, endpoint: "http://localhost:8000")

    assert {:error, %Error{type: :invalid_config}} =
             StoreSupervisor.start_link(HttpStore, :store_sup_test, [])

    assert :persistent_term.get({SurrealDB.Store, HttpStore}, :missing) == :missing
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/surreal_db/store/supervisor_test.exs`
Expected: FAIL — `SurrealDB.Store.Supervisor` is undefined.

- [ ] **Step 3: Implement the Supervisor (HTTP path)**

Create `lib/surreal_db/store/supervisor.ex`:

```elixir
defmodule SurrealDB.Store.Supervisor do
  @moduledoc false

  use Supervisor

  alias SurrealDB.Client
  alias SurrealDB.Config
  alias SurrealDB.Store.Server

  @spec start_link(module(), atom(), keyword()) ::
          {:ok, pid()} | {:error, SurrealDB.Error.t() | term()}
  def start_link(store, otp_app, opts) when is_atom(store) and is_atom(otp_app) do
    resolved = resolve_config(otp_app, store, opts)

    with {:ok, %Client{} = client} <- Config.build_client(resolved) do
      Supervisor.start_link(__MODULE__, {store, client, resolved},
        name: supervisor_name(store)
      )
    end
  end

  @impl true
  def init({store, %Client{} = client, _resolved}) do
    children = [
      {Server, {store, client}}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp resolve_config(otp_app, store, opts) do
    otp_app
    |> Application.get_env(store, [])
    |> Keyword.merge(opts)
  end

  defp supervisor_name(store), do: Module.concat(store, "Supervisor")
end
```

Note: `Config.build_client/1` ignores keys it does not recognize (e.g. a future `:websocket_options`), so passing the full merged config is safe.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/surreal_db/store/supervisor_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/surreal_db/store/supervisor.ex test/surreal_db/store/supervisor_test.exs
git commit -m "feat: add Store.Supervisor with config merge/validate (HTTP path)"
```

---

## Task 5: `SurrealDB.Store` macro + HTTP resolution + delegators

**Files:**
- Create: `lib/surreal_db/store.ex`
- Test: `test/surreal_db/store_test.exs` (create)

Implements the `__using__` macro (lifecycle + delegators) and the runtime resolution helpers. This task wires HTTP resolution (persistent_term only). The WS branch of `fetch_client/1` is added in Task 7.

- [ ] **Step 1: Write the failing test**

Create `test/surreal_db/store_test.exs`:

```elixir
defmodule SurrealDB.StoreTest do
  use ExUnit.Case, async: false

  alias SurrealDB.Client
  alias SurrealDB.Error
  alias SurrealDB.QueryResult

  defmodule HttpStore do
    use SurrealDB.Store, otp_app: :store_macro_test
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:store_macro_test, HttpStore)
      :persistent_term.erase({SurrealDB.Store, HttpStore})
    end)

    :ok
  end

  defp put_config(adapter) do
    Application.put_env(:store_macro_test, HttpStore,
      endpoint: "http://localhost:8000",
      namespace: "ns",
      database: "db",
      username: "root",
      password: "root",
      request_options: [adapter: adapter]
    )
  end

  test "client/0 returns not_started before the store is started" do
    assert {:error, %Error{type: :not_started}} = HttpStore.client()
  end

  test "query/2 resolves the started client and delegates to SurrealDB.query/3" do
    put_config(fn request ->
      assert request.body == "SELECT * FROM person"

      {request,
       Req.Response.new(
         status: 200,
         body: ~s([{"status":"OK","time":"1ms","result":[{"id":"person:one"}]}])
       )}
    end)

    start_supervised!(HttpStore)

    assert {:ok, %Client{namespace: "ns"}} = HttpStore.client()
    assert {:ok, %QueryResult{results: [[%{"id" => "person:one"}]]}} =
             HttpStore.query("SELECT * FROM person")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/surreal_db/store_test.exs`
Expected: FAIL — `SurrealDB.Store.__using__/1` is undefined (compile error in `HttpStore`).

- [ ] **Step 3: Implement the macro + resolution helpers**

Create `lib/surreal_db/store.ex`:

```elixir
defmodule SurrealDB.Store do
  @moduledoc """
  Defines a supervised, config-driven SurrealDB connection (Ecto.Repo-style).

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
        transport: :http

  Add the module to your supervision tree (`children = [MyApp.SurrealStore]`),
  then call the connection-bound API without an explicit client:

      MyApp.SurrealStore.query("SELECT * FROM person")
      MyApp.SurrealStore.get(MyApp.User, "user:abc")
      MyApp.SurrealStore.create(MyApp.User, %{name: "Jane"})
  """

  alias SurrealDB.Client
  alias SurrealDB.Error

  @doc false
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @otp_app Keyword.fetch!(opts, :otp_app)

      def child_spec(opts) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [opts]},
          type: :supervisor
        }
      end

      def start_link(opts \\ []) do
        SurrealDB.Store.Supervisor.start_link(__MODULE__, @otp_app, opts)
      end

      def config, do: SurrealDB.Store.config(@otp_app, __MODULE__)
      def client, do: SurrealDB.Store.fetch_client(__MODULE__)

      # Raw API (delegates to SurrealDB.*)
      def query(surql, vars \\ %{}) do
        with {:ok, c} <- client(), do: SurrealDB.query(c, surql, vars)
      end

      def rpc(method, params) do
        with {:ok, c} <- client(), do: SurrealDB.rpc(c, method, params)
      end

      def live(query, opts \\ []) do
        with {:ok, c} <- client(), do: SurrealDB.live(c, query, opts)
      end

      def kill(subscription) do
        with {:ok, c} <- client(), do: SurrealDB.kill(c, subscription)
      end

      # Schema-CRUD (delegates to SurrealDB.Repo.*)
      def get(schema, id, opts \\ []) do
        with {:ok, c} <- client(), do: SurrealDB.Repo.get(c, schema, id, opts)
      end

      def all(schema, filters \\ %{}, opts \\ []) do
        with {:ok, c} <- client(), do: SurrealDB.Repo.all(c, schema, filters, opts)
      end

      def find(schema, filters, opts \\ []) do
        with {:ok, c} <- client(), do: SurrealDB.Repo.find(c, schema, filters, opts)
      end

      def create(schema, attrs, opts \\ []) do
        with {:ok, c} <- client(), do: SurrealDB.Repo.create(c, schema, attrs, opts)
      end

      def update(schema, id, attrs, opts \\ []) do
        with {:ok, c} <- client(), do: SurrealDB.Repo.update(c, schema, id, attrs, opts)
      end

      def delete(schema, id, opts \\ []) do
        with {:ok, c} <- client(), do: SurrealDB.Repo.delete(c, schema, id, opts)
      end

      # Schema query (arity 3/4 only — avoids collision with raw query/1,2)
      def query(schema, surql, vars, opts \\ []) do
        with {:ok, c} <- client(), do: SurrealDB.Repo.query(c, schema, surql, vars, opts)
      end
    end
  end

  @doc false
  @spec config(atom(), module()) :: keyword()
  def config(otp_app, store) do
    Application.get_env(otp_app, store, [])
  end

  @doc false
  @spec fetch_client(module()) :: {:ok, Client.t()} | {:error, Error.t()}
  def fetch_client(store) do
    case :persistent_term.get({__MODULE__, store}, :not_started) do
      :not_started -> {:error, Error.not_started(store)}
      %Client{} = client -> resolve_transport(store, client)
    end
  end

  defp resolve_transport(_store, %Client{transport: :http} = client), do: {:ok, client}
end
```

Note: the `resolve_transport/2` clause for `:websocket` is added in Task 7. For now only HTTP stores resolve.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/surreal_db/store_test.exs`
Expected: PASS

- [ ] **Step 5: Run the full suite to check for regressions**

Run: `mix test`
Expected: PASS (existing tests unaffected; `SurrealDB.Repo` and `SurrealDB` untouched).

- [ ] **Step 6: Commit**

```bash
git add lib/surreal_db/store.ex test/surreal_db/store_test.exs
git commit -m "feat: add SurrealDB.Store macro with HTTP resolution and delegators"
```

---

## Task 6: WebSocket `Connection` — `:name` and opt-in `:reconnect`

**Files:**
- Modify: `lib/surreal_db/web_socket/connection.ex`
- Test: add to `test/surreal_db/web_socket_test.exs`

Adds two backward-compatible options to `Connection.start_link/2`:
- `:name` — passed to `GenServer.start_link` so the Store can register the process via `{:via, Registry, ...}`.
- `:reconnect` (default `false`) — when `true`, on `{:websocket_closed, _}` the process fails pending callers, drops to a not-ready state, and schedules a reconnect with backoff (keeping the same pid). The legacy `connect_ws/1` path keeps the default `false` (stop on close, today's behavior).

- [ ] **Step 1: Write the failing test**

Add to `test/surreal_db/web_socket_test.exs` (inside the module, after the last test):

```elixir
  test "reconnect: true keeps the process alive and reconnects after close" do
    client = websocket_client(request_options: [test_pid: self(), auto_setup: true])

    {:ok, pid} =
      SurrealDB.WebSocket.Connection.start_link(client,
        socket_module: FakeSocket,
        timeout: 50,
        reconnect: true,
        reconnect_backoff: 10
      )

    wait_for_setup()

    # Simulate the socket dropping.
    send(pid, {:websocket_closed, :closed})

    # The connection process survives and re-runs setup against a fresh socket.
    assert Process.alive?(pid)
    assert_receive {:fake_socket_started, ^pid, _url, _headers, _socket_pid}, 200
    assert_receive {:socket_sent, ^pid, _payload}, 200
  end

  test "name: registers the process via a Registry via-tuple" do
    {:ok, _} = Registry.start_link(keys: :unique, name: __MODULE__.Registry)
    client = websocket_client(request_options: [test_pid: self(), auto_setup: true])
    via = {:via, Registry, {__MODULE__.Registry, :conn}}

    {:ok, pid} =
      SurrealDB.WebSocket.Connection.start_link(client,
        socket_module: FakeSocket,
        timeout: 50,
        name: via
      )

    assert [{^pid, _}] = Registry.lookup(__MODULE__.Registry, :conn)
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/surreal_db/web_socket_test.exs`
Expected: FAIL — `:name` is ignored (no registration) and `reconnect` close still stops the process.

- [ ] **Step 3: Implement `:name` support**

In `lib/surreal_db/web_socket/connection.ex`, replace `start_link/2`:

```elixir
  @spec start_link(Client.t(), keyword()) :: GenServer.on_start()
  def start_link(%Client{} = client, options \\ []) do
    case Keyword.fetch(options, :name) do
      {:ok, name} -> GenServer.start_link(__MODULE__, {client, options}, name: name)
      :error -> GenServer.start_link(__MODULE__, {client, options})
    end
  end
```

- [ ] **Step 4: Implement `:reconnect` state + close handling**

In the same file, extend the `State` struct to carry reconnect settings. Replace the `defmodule State` block:

```elixir
  defmodule State do
    @moduledoc false
    defstruct [
      :client,
      :socket_pid,
      :socket_module,
      :connect_timeout,
      :setup_complete?,
      reconnect?: false,
      reconnect_backoff: 500,
      pending: %{},
      subscriptions: %{}
    ]
  end
```

Replace the `init/1` clause to read the new options:

```elixir
  @impl true
  def init({client, options}) do
    socket_module = Keyword.get(options, :socket_module, SurrealDB.WebSocket.Socket)
    connect_timeout = Keyword.get(options, :timeout, @default_timeout)

    state = %State{
      client: client,
      socket_module: socket_module,
      connect_timeout: connect_timeout,
      setup_complete?: false,
      reconnect?: Keyword.get(options, :reconnect, false),
      reconnect_backoff: Keyword.get(options, :reconnect_backoff, 500)
    }

    {:ok, state, {:continue, :connect}}
  end
```

Replace the `handle_info({:websocket_closed, reason}, ...)` clause:

```elixir
  def handle_info({:websocket_closed, reason}, %State{reconnect?: true} = state) do
    error = %Error{type: :websocket_closed, message: "websocket connection closed", raw: reason}
    fail_all_pending(state.pending, error)
    Process.send_after(self(), :reconnect, state.reconnect_backoff)
    {:noreply, %State{state | pending: %{}, setup_complete?: false, socket_pid: nil}}
  end

  def handle_info({:websocket_closed, reason}, %State{} = state) do
    error = %Error{type: :websocket_closed, message: "websocket connection closed", raw: reason}
    fail_all_pending(state.pending, error)
    {:stop, :normal, %State{state | pending: %{}}}
  end

  def handle_info(:reconnect, %State{} = state) do
    {:noreply, state, {:continue, :connect}}
  end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/surreal_db/web_socket_test.exs`
Expected: PASS (new tests pass; all existing WS tests still pass — `reconnect` defaults to `false`, so close still stops by default).

- [ ] **Step 6: Commit**

```bash
git add lib/surreal_db/web_socket/connection.ex test/surreal_db/web_socket_test.exs
git commit -m "feat: WebSocket.Connection supports :name and opt-in :reconnect"
```

---

## Task 7: WebSocket Store path — supervised reconnecting connection + WS resolution

**Files:**
- Modify: `lib/surreal_db/store/supervisor.ex`
- Modify: `lib/surreal_db/store.ex`
- Test: add to `test/surreal_db/store_test.exs`

The Supervisor starts a `WebSocket.Connection` child (for `transport: :websocket`) named via `{:via, Registry, {SurrealDB.Store.Registry, store}}`, with `reconnect: true`, passing through any configured `:websocket_options`. `fetch_client/1` gains a `:websocket` branch that looks up the live pid in the Registry.

- [ ] **Step 1: Write the failing test**

Add to `test/surreal_db/store_test.exs` (inside the module). It reuses the `FakeSocket` from the WS test suite via a fully-qualified reference:

```elixir
  defmodule WsStore do
    use SurrealDB.Store, otp_app: :store_macro_test
  end

  test "websocket store resolves the live connection pid and runs a query" do
    Application.put_env(:store_macro_test, WsStore,
      endpoint: "ws://localhost:8000/rpc",
      namespace: "ns",
      database: "db",
      username: "root",
      password: "root",
      transport: :websocket,
      request_options: [test_pid: self(), auto_setup: true],
      websocket_options: [socket_module: SurrealDB.WebSocketTest.FakeSocket, timeout: 50]
    )

    on_exit(fn -> Application.delete_env(:store_macro_test, WsStore) end)

    start_supervised!(WsStore)

    # setup traffic (signin + use)
    assert_receive {:socket_sent, _owner, _p1}
    assert_receive {:socket_sent, _owner, _p2}

    assert {:ok, %Client{transport: :websocket, connection: conn}} = WsStore.client()
    assert is_pid(conn)

    task = Task.async(fn -> WsStore.query("SELECT * FROM person") end)

    assert_receive {:socket_sent, owner, payload}
    decoded = Jason.decode!(payload)

    send(
      owner,
      {:websocket_frame,
       Jason.encode!(%{
         id: decoded["id"],
         result: [%{"status" => "OK", "result" => [%{"id" => "person:one"}]}]
       })}
    )

    assert {:ok, %QueryResult{results: [[%{"id" => "person:one"}]]}} = Task.await(task)
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/surreal_db/store_test.exs`
Expected: FAIL — the Supervisor starts no WS connection, so `WsStore.client()` returns `{:error, %Error{type: :not_connected}}` (and no `:websocket` clause exists yet in `resolve_transport/2`).

- [ ] **Step 3: Add the WS child to the Supervisor**

In `lib/surreal_db/store/supervisor.ex`, replace `init/2` and add a child-builder. The full updated module:

```elixir
defmodule SurrealDB.Store.Supervisor do
  @moduledoc false

  use Supervisor

  alias SurrealDB.Client
  alias SurrealDB.Config
  alias SurrealDB.Store.Server
  alias SurrealDB.WebSocket.Connection

  @spec start_link(module(), atom(), keyword()) ::
          {:ok, pid()} | {:error, SurrealDB.Error.t() | term()}
  def start_link(store, otp_app, opts) when is_atom(store) and is_atom(otp_app) do
    resolved = resolve_config(otp_app, store, opts)

    with {:ok, %Client{} = client} <- Config.build_client(resolved) do
      Supervisor.start_link(__MODULE__, {store, client, resolved},
        name: supervisor_name(store)
      )
    end
  end

  @impl true
  def init({store, %Client{} = client, resolved}) do
    children = [{Server, {store, client}}] ++ connection_children(store, client, resolved)
    Supervisor.init(children, strategy: :one_for_one)
  end

  defp connection_children(store, %Client{transport: :websocket} = client, resolved) do
    via = {:via, Registry, {SurrealDB.Store.Registry, store}}

    connection_opts =
      resolved
      |> Keyword.get(:websocket_options, [])
      |> Keyword.merge(name: via, reconnect: true)

    [
      %{
        id: Connection,
        start: {Connection, :start_link, [client, connection_opts]},
        restart: :permanent
      }
    ]
  end

  defp connection_children(_store, %Client{}, _resolved), do: []

  defp resolve_config(otp_app, store, opts) do
    otp_app
    |> Application.get_env(store, [])
    |> Keyword.merge(opts)
  end

  defp supervisor_name(store), do: Module.concat(store, "Supervisor")
end
```

- [ ] **Step 4: Add the WS branch to `fetch_client/1`**

In `lib/surreal_db/store.ex`, replace the single `resolve_transport/2` clause with both clauses:

```elixir
  defp resolve_transport(_store, %Client{transport: :http} = client), do: {:ok, client}

  defp resolve_transport(store, %Client{transport: :websocket} = client) do
    case Registry.lookup(SurrealDB.Store.Registry, store) do
      [{pid, _value}] -> {:ok, %Client{client | connection: pid}}
      [] -> {:error, Error.not_connected(store)}
    end
  end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/surreal_db/store_test.exs`
Expected: PASS

- [ ] **Step 6: Run the full suite**

Run: `mix test`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add lib/surreal_db/store/supervisor.ex lib/surreal_db/store.ex test/surreal_db/store_test.exs
git commit -m "feat: supervise reconnecting WS connection and resolve it by store"
```

---

## Task 8: Installer — scaffold store module, supervision child, per-app config

**Files:**
- Modify: `lib/mix/tasks/hgs_surrealdb_sdk.install.ex`
- Test: rewrite `test/mix/tasks/hgs_surrealdb_sdk_install_test.exs`

The installer now generates `<App>.SurrealStore` (`use SurrealDB.Store, otp_app: <app>`), adds it to the app supervision tree, and writes `config <app>, <App>.SurrealStore, [...]` instead of `config :hgs_surrealdb_sdk, connection: [...]`.

- [ ] **Step 1: Read the existing installer test to match Igniter.Test conventions**

Run: `sed -n '1,80p' test/mix/tasks/hgs_surrealdb_sdk_install_test.exs`
Expected: shows how the current test asserts on generated config (use the same `Igniter.Test` helpers — `Igniter.Test.assert_creates/3`, `assert_has_patch/2`, or `Igniter.Project.Config` assertions — that the file already uses).

- [ ] **Step 2: Write the failing test**

Replace `test/mix/tasks/hgs_surrealdb_sdk_install_test.exs` with assertions for the new behavior. Use the same Igniter test helpers the previous version used:

```elixir
defmodule Mix.Tasks.HgsSurrealdbSdk.InstallTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  test "generates a store module" do
    test_project()
    |> Igniter.compose_task("hgs_surrealdb_sdk.install", [])
    |> assert_creates("lib/test/surreal_store.ex", """
    defmodule Test.SurrealStore do
      use SurrealDB.Store, otp_app: :test
    end
    """)
  end

  test "writes per-app store config" do
    test_project()
    |> Igniter.compose_task("hgs_surrealdb_sdk.install", [
      "--namespace",
      "app",
      "--database",
      "app"
    ])
    |> assert_has_patch("config/config.exs", """
    + |config :test, Test.SurrealStore,
    + |  endpoint: "http://localhost:8000",
    + |  namespace: "app",
    + |  database: "app",
    + |  username: "root",
    + |  password: "root"
    """)
  end

  test "adds the store to the application supervision tree" do
    test_project()
    |> Igniter.compose_task("hgs_surrealdb_sdk.install", [])
    |> assert_has_patch("lib/test/application.ex", """
    + |      Test.SurrealStore
    """)
  end
end
```

Note: `test_project/0` from `Igniter.Test` builds a project whose OTP app is `:test` and whose base module is `Test`. If the existing test used a different app/module name, mirror that instead and adjust the expected strings to match.

- [ ] **Step 3: Run test to verify it fails**

Run: `mix test test/mix/tasks/hgs_surrealdb_sdk_install_test.exs`
Expected: FAIL — installer still writes `config :hgs_surrealdb_sdk, connection: [...]` and creates no module.

- [ ] **Step 4: Implement the new installer**

Replace the `igniter/1` function in `lib/mix/tasks/hgs_surrealdb_sdk.install.ex`:

```elixir
  @impl Igniter.Mix.Task
  def igniter(igniter) do
    opts = igniter.args.options
    endpoint = opts[:endpoint] || "http://localhost:8000"
    namespace = opts[:namespace] || "test"
    database = opts[:database] || "test"

    app = Igniter.Project.Application.app_name(igniter)
    store = Module.concat(Igniter.Project.Module.module_name_prefix(igniter), SurrealStore)

    igniter
    |> Igniter.Project.Module.create_module(store, """
    use SurrealDB.Store, otp_app: #{inspect(app)}
    """)
    |> Igniter.Project.Config.configure("config.exs", app, [store, :endpoint], endpoint)
    |> Igniter.Project.Config.configure("config.exs", app, [store, :namespace], namespace)
    |> Igniter.Project.Config.configure("config.exs", app, [store, :database], database)
    |> Igniter.Project.Config.configure("config.exs", app, [store, :username], "root")
    |> Igniter.Project.Config.configure("config.exs", app, [store, :password], "root")
    |> Igniter.Project.Application.add_new_child(store)
    |> Igniter.add_notice("""
    SurrealDB store #{inspect(store)} generated and added to your supervision tree.

    Connection config written to config/config.exs under `config #{inspect(app)},
    #{inspect(store)}`. The default credentials are root/root for a local dev
    server. Override them (and the endpoint) per environment in
    config/runtime.exs before deploying, and make sure the target
    namespace/database exist on the server.

    Call it without an explicit client, e.g. `#{inspect(store)}.query("INFO FOR DB")`.
    """)
  end
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mix test test/mix/tasks/hgs_surrealdb_sdk_install_test.exs`
Expected: PASS. If an assertion mismatches on exact formatting (Igniter normalizes whitespace), adjust the expected patch text to match the actual generated output shown in the failure diff — do not change the installer to chase formatting.

- [ ] **Step 6: Commit**

```bash
git add lib/mix/tasks/hgs_surrealdb_sdk.install.ex test/mix/tasks/hgs_surrealdb_sdk_install_test.exs
git commit -m "feat: installer scaffolds SurrealDB.Store module + supervision child"
```

---

## Task 9: Documentation — README and ROADMAP

**Files:**
- Modify: `README.md`
- Modify: `ROADMAP.md`

- [ ] **Step 1: Read the relevant README sections**

Run: `grep -n "Configuration (required)\|connection:\|SurrealDB.connect" README.md`
Expected: locates the "Configuration (required)" section and connect examples to reframe.

- [ ] **Step 2: Add a "Supervised connection (SurrealDB.Store)" section to README**

Insert after the existing "Configuration (required)" section. Use this content:

````markdown
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
releases work naturally. `mix igniter.install hgs_surrealdb_sdk` scaffolds the
store module, the supervision-tree entry, and this config block for you.
````

- [ ] **Step 3: Reframe the "Configuration (required)" wording**

In `README.md`, change the wording that says config is required for the SDK to *boot* to say it is required only for the legacy app-level client (`SurrealDB.connect/0`); the SDK application itself now boots without it. Keep the `config :hgs_surrealdb_sdk, connection: [...]` example for that legacy path.

- [ ] **Step 4: Move F2 to Done in ROADMAP**

In `ROADMAP.md`, remove the `F2` bullet from "Backlog (nice-to-have)" and add under "Done":

```markdown
- **F2 — Supervised connection (`SurrealDB.Store`).** `use SurrealDB.Store,
  otp_app: :my_app` starts a named, supervised, config-driven connection under
  the host's supervision tree (HTTP and reconnecting WebSocket). Calls drop the
  explicit client. The SDK application now boots gracefully without
  `config :hgs_surrealdb_sdk, connection: [...]` (starting only a Registry), and
  connection config is resolved at store start (runtime) — resolving the
  deferred boot-vs-runtime tension. The installer scaffolds the store module,
  supervision child, and per-app config.
```

Also remove the deferred "Make the OTP application boot gracefully when `:connection` is absent" bullet, since F2 implements it.

- [ ] **Step 5: Verify the docs compile (doctests/examples)**

Run: `mix test`
Expected: PASS (no doctests added that would execute; this confirms nothing else broke).

- [ ] **Step 6: Commit**

```bash
git add README.md ROADMAP.md
git commit -m "docs: document SurrealDB.Store and mark F2 done"
```

---

## Final verification

- [ ] Run the whole suite: `mix test` → all pass.
- [ ] Run formatter check: `mix format --check-formatted` → clean (run `mix format` if not).
- [ ] Confirm no `:connection`-at-boot requirement remains: `grep -rn "build_application_client" lib/` should show it only in `SurrealDB.Config`/`SurrealDB.connect`, not in `application.ex`.

---

## Self-review notes (author)

- **Spec coverage:** programming model + surface (Task 5), naming-collision decision via query arity split (Task 5), SDK app boots gracefully + Registry (Task 1), config under `config :my_app, MyApp.Store` read at child start with inline-override precedence (Task 4), persistent_term static client + Registry WS pid resolution (Tasks 5, 7), per-transport supervision with reconnecting WS (Tasks 6, 7), error handling `:invalid_config`/`:not_started`/`:not_connected` (Tasks 2, 4, 5, 7), installer update (Task 8), back-compat reframing + ROADMAP (Task 9). All spec sections map to a task.
- **Type consistency:** persistent_term key `{SurrealDB.Store, store}` used identically in Server (write/erase), `fetch_client/1` (read), and all tests. Registry name `SurrealDB.Store.Registry` and key `store` (the module) used identically in app boot, Supervisor via-tuple, and `resolve_transport/2`. `fetch_client/1` returns `{:ok, Client.t()} | {:error, Error.t()}`; every delegator consumes it via `with {:ok, c} <- client()`.
- **Escape hatch refinement:** the spec described `client()` returning a bare `%Client{}`; the plan returns `{:ok, client} | {:error, error}` so resolution failures are expressible and consistent with the rest of the API. This is an intentional, documented refinement.
