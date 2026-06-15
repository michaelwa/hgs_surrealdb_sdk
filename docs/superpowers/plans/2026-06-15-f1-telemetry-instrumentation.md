# F1 — Telemetry Instrumentation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Emit `:telemetry` start/stop/exception spans around query/RPC execution (both transports) plus discrete WebSocket connection-lifecycle events, and ship a documented `SurrealDB.Telemetry` consumer module with an opt-in default logger.

**Architecture:** A single `[:surreal_db, :query]` span family is emitted via `:telemetry.span/3` at the two top-level execution boundaries that hold a `%SurrealDB.Client{}`: `SurrealDB.RPC.call/3` (covers query/rpc/CRUD/Repo/Store on both transports) and `SurrealDB.Live.start/3` + `SurrealDB.Live.kill/2` (live queries). A separate `[:surreal_db, :connection]` event family is emitted as discrete events from `SurrealDB.WebSocket.Connection`. All metadata construction and the query-text redaction rule live in one place: `SurrealDB.Telemetry`. Instrumentation is purely additive — no return values or error shapes change.

**Tech Stack:** Elixir, `:telemetry` (~> 1.0), ExUnit, `Req.Test` adapter stubs (HTTP), an injectable fake socket module (WebSocket).

**Spec:** `docs/superpowers/specs/2026-06-15-f1-telemetry-instrumentation-design.md`

---

## File Structure

- **Create** `lib/surreal_db/telemetry.ex` — `SurrealDB.Telemetry`: public `events/0` + `attach_default_logger/1` + `detach_default_logger/0` + `handle_event/4`; internal (`@doc false`) `span/4`, `start_metadata/3`, `stop_metadata/2`, `include_query_text?/0`. Single home for the metadata-safety rule.
- **Create** `test/surreal_db/telemetry_test.exs` — unit tests for `events/0`, metadata builders, redaction, the span exception path, and the default logger.
- **Modify** `lib/surreal_db/rpc.ex` — wrap dispatch in `SurrealDB.Telemetry.span/4`.
- **Modify** `lib/surreal_db/live.ex` — wrap the execution paths of `start/3` and `kill/2`.
- **Modify** `lib/surreal_db/web_socket/connection.ex` — `:store` + `connect_count` state, emit connected/disconnected/reconnecting events, centralize reconnect scheduling.
- **Modify** `lib/surreal_db/store/supervisor.ex` — thread `store:` into connection opts.
- **Modify** `mix.exs` — declare `{:telemetry, "~> 1.0"}` explicitly.
- **Add tests to** `test/surreal_db/web_socket_test.exs` — connection-lifecycle events; **add to** `test/surreal_db/http_test.exs` or `telemetry_test.exs` — HTTP span; reuse the live-query pattern for the Live span.
- **Modify** `README.md` and `ROADMAP.md` — document events; move F1 to Done.

---

## Task 1: Add `:telemetry` dependency and `SurrealDB.Telemetry.events/0`

**Files:**
- Modify: `mix.exs:28-33` (the `deps/0` list)
- Create: `lib/surreal_db/telemetry.ex`
- Test: `test/surreal_db/telemetry_test.exs`

- [ ] **Step 1: Add the dependency**

In `mix.exs`, inside `defp deps do [...] end`, add the telemetry line alongside the existing deps:

```elixir
defp deps do
  [
    {:req, "~> 0.5"},
    {:jason, "~> 1.4"},
    {:telemetry, "~> 1.0"},
    # ...keep any other existing entries unchanged...
  ]
end
```

- [ ] **Step 2: Fetch deps**

Run: `mix deps.get`
Expected: resolves without error (telemetry is already in `mix.lock` transitively).

- [ ] **Step 3: Write the failing test**

Create `test/surreal_db/telemetry_test.exs`:

```elixir
defmodule SurrealDB.TelemetryTest do
  use ExUnit.Case, async: true

  alias SurrealDB.Telemetry

  test "events/0 lists every emitted event" do
    assert Telemetry.events() == [
             [:surreal_db, :query, :start],
             [:surreal_db, :query, :stop],
             [:surreal_db, :query, :exception],
             [:surreal_db, :connection, :connected],
             [:surreal_db, :connection, :disconnected],
             [:surreal_db, :connection, :reconnecting]
           ]
  end
end
```

- [ ] **Step 4: Run test to verify it fails**

Run: `mix test test/surreal_db/telemetry_test.exs`
Expected: FAIL — `SurrealDB.Telemetry.events/0 is undefined`.

- [ ] **Step 5: Create the module with events/0**

Create `lib/surreal_db/telemetry.ex`:

```elixir
defmodule SurrealDB.Telemetry do
  @moduledoc """
  Telemetry events emitted by the SurrealDB SDK.

  (Full event reference filled in Task 7.)
  """

  @query_event [:surreal_db, :query]

  @doc """
  Lists every telemetry event the SDK emits. Useful for `Telemetry.Metrics`
  specs and tests.
  """
  @spec events() :: [[atom()]]
  def events do
    [
      @query_event ++ [:start],
      @query_event ++ [:stop],
      @query_event ++ [:exception],
      [:surreal_db, :connection, :connected],
      [:surreal_db, :connection, :disconnected],
      [:surreal_db, :connection, :reconnecting]
    ]
  end
end
```

- [ ] **Step 6: Run test to verify it passes**

Run: `mix test test/surreal_db/telemetry_test.exs`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add mix.exs mix.lock lib/surreal_db/telemetry.ex test/surreal_db/telemetry_test.exs
git commit -m "feat: add :telemetry dep and SurrealDB.Telemetry.events/0

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Metadata builders and redaction rule

**Files:**
- Modify: `lib/surreal_db/telemetry.ex`
- Test: `test/surreal_db/telemetry_test.exs`

- [ ] **Step 1: Write the failing tests**

Add to `test/surreal_db/telemetry_test.exs` (add `alias SurrealDB.Client` and `alias SurrealDB.Error` at the top):

```elixir
describe "start_metadata/3" do
  setup do
    client = %Client{
      endpoint: "http://localhost:8000",
      namespace: "test",
      database: "app",
      transport: :http
    }

    %{client: client}
  end

  test "always includes safe fields", %{client: client} do
    meta = Telemetry.start_metadata(client, "query", query: "SELECT 1")

    assert meta.method == "query"
    assert meta.namespace == "test"
    assert meta.database == "app"
    assert meta.transport == :http
    assert meta.endpoint == "http://localhost:8000"
  end

  test "includes query text by default", %{client: client} do
    meta = Telemetry.start_metadata(client, "query", query: "SELECT * FROM person")
    assert meta.query == "SELECT * FROM person"
  end

  test "redacts query text when configured", %{client: client} do
    Application.put_env(:hgs_surrealdb_sdk, :telemetry, include_query_text: false)
    on_exit(fn -> Application.delete_env(:hgs_surrealdb_sdk, :telemetry) end)

    meta = Telemetry.start_metadata(client, "query", query: "SELECT secret")
    assert meta.query == :"[redacted]"
  end

  test "emits variable keys and count, never values", %{client: client} do
    meta =
      Telemetry.start_metadata(client, "query",
        query: "CREATE person CONTENT $data",
        variables: %{data: %{password: "hunter2"}, id: 1}
      )

    assert Enum.sort(meta.variable_keys) == [:data, :id]
    assert meta.variable_count == 2
    refute meta |> inspect() |> String.contains?("hunter2")
  end

  test "emits params_count for non-query RPCs", %{client: client} do
    meta = Telemetry.start_metadata(client, "use", params: ["test", "app"])
    assert meta.params_count == 2
    refute Map.has_key?(meta, :query)
  end
end

describe "stop_metadata/2" do
  test "marks ok results" do
    start = %{method: "query"}
    assert Telemetry.stop_metadata(start, {:ok, :anything}) == %{method: "query", result: :ok, error: nil}
    assert Telemetry.stop_metadata(start, :ok) == %{method: "query", result: :ok, error: nil}
  end

  test "captures the error struct on failure" do
    start = %{method: "query"}
    error = %Error{type: :transport_error, message: "boom"}
    stop = Telemetry.stop_metadata(start, {:error, error})
    assert stop.result == :error
    assert stop.error == error
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/surreal_db/telemetry_test.exs`
Expected: FAIL — `start_metadata/3` / `stop_metadata/2` undefined.

- [ ] **Step 3: Implement the builders**

Add to `lib/surreal_db/telemetry.ex` (add `alias SurrealDB.Client` and `alias SurrealDB.Error` near the top):

```elixir
@doc false
@spec start_metadata(Client.t(), String.t(), keyword()) :: map()
def start_metadata(%Client{} = client, method, fields) do
  %{
    method: method,
    namespace: client.namespace,
    database: client.database,
    transport: client.transport,
    endpoint: client.endpoint
  }
  |> put_query(Keyword.get(fields, :query))
  |> put_variables(Keyword.get(fields, :variables))
  |> put_params(Keyword.get(fields, :params))
end

@doc false
@spec stop_metadata(map(), term()) :: map()
def stop_metadata(start_meta, :ok), do: Map.merge(start_meta, %{result: :ok, error: nil})
def stop_metadata(start_meta, {:ok, _}), do: Map.merge(start_meta, %{result: :ok, error: nil})

def stop_metadata(start_meta, {:error, %Error{} = error}),
  do: Map.merge(start_meta, %{result: :error, error: error})

def stop_metadata(start_meta, {:error, other}),
  do: Map.merge(start_meta, %{result: :error, error: other})

@doc false
@spec include_query_text?() :: boolean()
def include_query_text? do
  :hgs_surrealdb_sdk
  |> Application.get_env(:telemetry, [])
  |> Keyword.get(:include_query_text, true)
end

defp put_query(meta, nil), do: meta

defp put_query(meta, query) do
  value = if include_query_text?(), do: IO.iodata_to_binary(query), else: :"[redacted]"
  Map.put(meta, :query, value)
end

defp put_variables(meta, nil), do: meta

defp put_variables(meta, variables) when is_map(variables) do
  meta
  |> Map.put(:variable_keys, Map.keys(variables))
  |> Map.put(:variable_count, map_size(variables))
end

defp put_params(meta, nil), do: meta
defp put_params(meta, params) when is_list(params), do: Map.put(meta, :params_count, length(params))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/surreal_db/telemetry_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/surreal_db/telemetry.ex test/surreal_db/telemetry_test.exs
git commit -m "feat: telemetry metadata builders with query-text redaction

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: `span/4` helper and instrument `RPC.call/3`

**Files:**
- Modify: `lib/surreal_db/telemetry.ex`
- Modify: `lib/surreal_db/rpc.ex`
- Test: `test/surreal_db/telemetry_test.exs`

- [ ] **Step 1: Write the failing tests for span/4 (success, error, exception)**

Add to `test/surreal_db/telemetry_test.exs`:

```elixir
describe "span/4" do
  setup do
    client = %Client{endpoint: "http://x", namespace: "n", database: "d", transport: :http}
    events = [[:surreal_db, :query, :start], [:surreal_db, :query, :stop], [:surreal_db, :query, :exception]]
    test_pid = self()
    handler_id = {:test, System.unique_integer()}

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, meta, _ -> send(test_pid, {:telemetry, event, measurements, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    %{client: client}
  end

  test "emits start then stop on success", %{client: client} do
    result = Telemetry.span(client, "query", [query: "SELECT 1"], fn -> {:ok, :resp} end)

    assert result == {:ok, :resp}
    assert_receive {:telemetry, [:surreal_db, :query, :start], %{system_time: _}, %{method: "query"}}
    assert_receive {:telemetry, [:surreal_db, :query, :stop], %{duration: _}, %{result: :ok, error: nil}}
  end

  test "stop carries the error on failure", %{client: client} do
    error = %Error{type: :transport_error, message: "boom"}
    assert Telemetry.span(client, "query", [], fn -> {:error, error} end) == {:error, error}
    assert_receive {:telemetry, [:surreal_db, :query, :stop], _, %{result: :error, error: ^error}}
  end

  test "raises propagate and emit an exception event", %{client: client} do
    assert_raise RuntimeError, "kaboom", fn ->
      Telemetry.span(client, "query", [], fn -> raise "kaboom" end)
    end

    assert_receive {:telemetry, [:surreal_db, :query, :exception], %{duration: _},
                    %{kind: :error, reason: %RuntimeError{}}}
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/surreal_db/telemetry_test.exs`
Expected: FAIL — `span/4` undefined.

- [ ] **Step 3: Implement span/4**

Add to `lib/surreal_db/telemetry.ex`:

```elixir
@doc false
@spec span(Client.t(), String.t(), keyword(), (-> result)) :: result when result: term()
def span(%Client{} = client, method, fields, fun) when is_function(fun, 0) do
  start_meta = start_metadata(client, method, fields)

  :telemetry.span(@query_event, start_meta, fn ->
    result = fun.()
    {result, stop_metadata(start_meta, result)}
  end)
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/surreal_db/telemetry_test.exs`
Expected: PASS (`:telemetry.span/3` emits `:start`/`:stop`, and `:exception` with `kind`/`reason`/`stacktrace` on raise, re-raising).

- [ ] **Step 5: Write the failing test for RPC instrumentation (HTTP)**

Add to `test/surreal_db/telemetry_test.exs` (reuses the `Req` adapter pattern from `test/surreal_db/http_test.exs`):

```elixir
describe "RPC.call instrumentation (HTTP)" do
  setup do
    handler_id = {:rpc, System.unique_integer()}
    test_pid = self()

    :telemetry.attach_many(
      handler_id,
      [[:surreal_db, :query, :start], [:surreal_db, :query, :stop]],
      fn event, _m, meta, _ -> send(test_pid, {:telemetry, event, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  defp ok_client do
    %Client{
      endpoint: "http://localhost:8000",
      namespace: "test",
      database: "app",
      auth: {:basic, %{username: "root", password: "root"}},
      request_options: [
        adapter: fn request ->
          {request, Req.Response.new(status: 200, body: ~s([{"status":"OK","result":[]}]))}
        end
      ]
    }
  end

  test "a successful query emits a stop with result :ok and the query text" do
    assert {:ok, _} = SurrealDB.query(ok_client(), "SELECT * FROM person")

    assert_receive {:telemetry, [:surreal_db, :query, :start], %{method: "query", query: "SELECT * FROM person", transport: :http}}
    assert_receive {:telemetry, [:surreal_db, :query, :stop], %{result: :ok}}
  end

  test "a transport failure emits a stop with result :error" do
    client = %Client{
      ok_client()
      | request_options: [adapter: fn request -> {request, Req.Response.new(status: 401, body: ~s({"error":"nope"}))} end]
    }

    assert {:error, %Error{}} = SurrealDB.rpc(client, "query", ["SELECT 1"])
    assert_receive {:telemetry, [:surreal_db, :query, :stop], %{result: :error, error: %Error{}}}
  end
end
```

- [ ] **Step 6: Run test to verify it fails**

Run: `mix test test/surreal_db/telemetry_test.exs`
Expected: FAIL — no telemetry messages received (RPC.call not yet instrumented).

- [ ] **Step 7: Instrument RPC.call/3**

Replace the body of `lib/surreal_db/rpc.ex` with (keeps the existing dispatch logic, wraps it in a span):

```elixir
defmodule SurrealDB.RPC do
  @moduledoc false

  alias SurrealDB.Client
  alias SurrealDB.Error
  alias SurrealDB.RPC.Request
  alias SurrealDB.RPC.Response
  alias SurrealDB.Telemetry
  alias SurrealDB.Transport.HTTP
  alias SurrealDB.Transport.WebSocket

  @spec call(Client.t(), String.t(), list()) :: {:ok, Response.t()} | {:error, Error.t()}
  def call(%Client{} = client, method, params \\ []) when is_binary(method) and is_list(params) do
    Telemetry.span(client, method, telemetry_fields(method, params), fn ->
      do_call(client, method, params)
    end)
  end

  defp do_call(%Client{} = client, method, params) do
    request = Request.new(method, params)

    with {:ok, %Response{} = response} <- transport(client).call(client, request) do
      case response.error do
        nil -> {:ok, response}
        _ -> {:error, Response.to_error(response)}
      end
    end
  end

  defp telemetry_fields("query", [query]), do: [query: query]
  defp telemetry_fields("query", [query, variables]), do: [query: query, variables: variables]
  defp telemetry_fields(_method, params), do: [params: params]

  defp transport(%Client{transport: :websocket}), do: WebSocket
  defp transport(%Client{}), do: HTTP
end
```

- [ ] **Step 8: Run the test to verify it passes**

Run: `mix test test/surreal_db/telemetry_test.exs`
Expected: PASS.

- [ ] **Step 9: Run the full suite to confirm no regressions**

Run: `mix test`
Expected: PASS (instrumentation is additive; existing RPC/HTTP/Repo/Store tests unaffected).

- [ ] **Step 10: Commit**

```bash
git add lib/surreal_db/telemetry.ex lib/surreal_db/rpc.ex test/surreal_db/telemetry_test.exs
git commit -m "feat: emit [:surreal_db, :query] span around RPC.call

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Instrument live-query `start/3` and `kill/2`

**Files:**
- Modify: `lib/surreal_db/live.ex`
- Test: `test/surreal_db/web_socket_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/surreal_db/web_socket_test.exs` (mirrors the existing "live query start" test at line 183, plus a telemetry handler):

```elixir
test "live query start emits a [:surreal_db, :query] span with method \"live\"" do
  {:ok, client} =
    SurrealDB.connect_ws(
      endpoint: "ws://localhost:8000/rpc",
      namespace: "test",
      database: "app",
      username: "root",
      password: "root",
      request_options: [test_pid: self(), auto_setup: true],
      websocket_options: [socket_module: FakeSocket, timeout: 50]
    )

  wait_for_setup()

  handler_id = {:live, System.unique_integer()}
  test_pid = self()

  :telemetry.attach(
    handler_id,
    [:surreal_db, :query, :stop],
    fn _e, _m, meta, _ -> send(test_pid, {:live_stop, meta}) end,
    nil
  )

  on_exit(fn -> :telemetry.detach(handler_id) end)

  task = Task.async(fn -> SurrealDB.live(client, "LIVE SELECT * FROM person", send_to: self()) end)

  assert_receive {:socket_sent, owner, payload}
  decoded = Jason.decode!(payload)

  send(
    owner,
    {:websocket_frame,
     Jason.encode!(%{id: decoded["id"], result: [%{"status" => "OK", "result" => "live-person"}]})}
  )

  assert {:ok, _subscription} = Task.await(task)
  assert_receive {:live_stop, %{method: "live", result: :ok, transport: :websocket}}
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/surreal_db/web_socket_test.exs`
Expected: FAIL — no `{:live_stop, ...}` message (Live not instrumented).

- [ ] **Step 3: Instrument Live.start/3 and Live.kill/2**

Edit `lib/surreal_db/live.ex`. Add `alias SurrealDB.Telemetry` near the other aliases, then wrap only the execution paths (the websocket-pid clauses). Leave the non-websocket guard clauses — which fail before any wire activity — uninstrumented.

```elixir
def start(%Client{transport: :websocket, connection: pid} = client, query, opts)
    when is_pid(pid) and is_binary(query) and is_list(opts) do
  target = Keyword.get(opts, :send_to, self())

  Telemetry.span(client, "live", [query: query], fn ->
    Connection.start_live_query(pid, query, target)
  end)
end
```

```elixir
def kill(%Client{transport: :websocket, connection: pid} = client, %Subscription{} = subscription)
    when is_pid(pid) do
  Telemetry.span(client, "kill", [], fn ->
    Connection.kill_live_query(pid, subscription)
  end)
end
```

Note: `start/3` and `kill/2` currently destructure the client without binding it (`%Client{transport: :websocket, connection: pid}`). Add `= client` to the pattern as shown so the struct is available for `Telemetry.span/4`. The non-websocket fallback clauses (`def start(%Client{}, ...)` / `def kill(%Client{}, ...)`) stay exactly as-is.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/surreal_db/web_socket_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/surreal_db/live.ex test/surreal_db/web_socket_test.exs
git commit -m "feat: emit query span around live-query start/kill

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: WebSocket connection-lifecycle events

**Files:**
- Modify: `lib/surreal_db/web_socket/connection.ex`
- Modify: `lib/surreal_db/store/supervisor.ex`
- Test: `test/surreal_db/web_socket_test.exs`

- [ ] **Step 1: Write the failing test for `:connected` and `:disconnected`**

Add to `test/surreal_db/web_socket_test.exs`:

```elixir
test "emits connection lifecycle events on connect, close, and reconnect" do
  client = websocket_client(request_options: [test_pid: self(), auto_setup: true])

  handler_id = {:conn, System.unique_integer()}
  test_pid = self()

  :telemetry.attach_many(
    handler_id,
    [
      [:surreal_db, :connection, :connected],
      [:surreal_db, :connection, :disconnected],
      [:surreal_db, :connection, :reconnecting]
    ],
    fn event, _m, meta, _ -> send(test_pid, {:conn_event, event, meta}) end,
    nil
  )

  on_exit(fn -> :telemetry.detach(handler_id) end)

  {:ok, pid} =
    SurrealDB.WebSocket.Connection.start_link(client,
      socket_module: FakeSocket,
      timeout: 50,
      reconnect: true,
      reconnect_backoff: 10
    )

  wait_for_setup()

  assert_receive {:conn_event, [:surreal_db, :connection, :connected],
                  %{namespace: "test", database: "app", reconnect?: false, store: nil}}

  send(pid, {:websocket_closed, :closed})

  assert_receive {:conn_event, [:surreal_db, :connection, :disconnected], %{will_reconnect?: true}}
  assert_receive {:conn_event, [:surreal_db, :connection, :reconnecting], %{backoff: 10}}
  assert_receive {:conn_event, [:surreal_db, :connection, :connected], %{reconnect?: true}}, 500
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/surreal_db/web_socket_test.exs`
Expected: FAIL — no `{:conn_event, ...}` messages.

- [ ] **Step 3: Add state fields and read the `:store` option**

In `lib/surreal_db/web_socket/connection.ex`, add the two fields to the `State` struct (in the `defmodule State` block):

```elixir
defstruct [
  :client,
  :socket_pid,
  :socket_module,
  :connect_timeout,
  :setup_complete?,
  :store,
  reconnect?: false,
  reconnect_backoff: 500,
  connect_count: 0,
  pending: %{},
  subscriptions: %{}
]
```

In `init/1`, set `store:` from options when building the initial state:

```elixir
state = %State{
  client: client,
  socket_module: socket_module,
  connect_timeout: connect_timeout,
  setup_complete?: false,
  store: Keyword.get(options, :store),
  reconnect?: Keyword.get(options, :reconnect, false),
  reconnect_backoff: Keyword.get(options, :reconnect_backoff, 500)
}
```

- [ ] **Step 4: Emit the `:connected` event in both connect handlers**

Replace the two `handle_info({:websocket_connected, _socket_pid}, ...)` clauses so each emits `:connected` and increments `connect_count` on success. The reconnect-enabled clause:

```elixir
def handle_info({:websocket_connected, _socket_pid}, %State{reconnect?: true} = state) do
  case perform_setup(state) do
    {:ok, %State{} = new_state} ->
      {:noreply, on_connected(new_state)}

    {:error, {:setup_failed, %Error{type: :websocket_closed}}, new_state} ->
      if is_pid(new_state.socket_pid), do: new_state.socket_module.close(new_state.socket_pid)
      new_state = schedule_reconnect(new_state)
      {:noreply, %State{new_state | pending: %{}, setup_complete?: false, socket_pid: nil}}

    {:error, reason, new_state} ->
      {:stop, reason, new_state}
  end
end

def handle_info({:websocket_connected, _socket_pid}, %State{} = state) do
  case perform_setup(state) do
    {:ok, %State{} = new_state} -> {:noreply, on_connected(new_state)}
    {:error, reason, new_state} -> {:stop, reason, new_state}
  end
end
```

- [ ] **Step 5: Add the `on_connected/1` and connection-event helpers**

Add these private functions to `lib/surreal_db/web_socket/connection.ex` (near the other `defp` helpers):

```elixir
defp on_connected(%State{} = state) do
  emit_connection_event(state, :connected, %{reconnect?: state.connect_count > 0})
  %State{state | setup_complete?: true, connect_count: state.connect_count + 1}
end

defp schedule_reconnect(%State{} = state) do
  emit_connection_event(state, :reconnecting, %{backoff: state.reconnect_backoff})
  Process.send_after(self(), :reconnect, state.reconnect_backoff)
  state
end

defp emit_connection_event(%State{client: client, store: store}, name, extra) do
  metadata =
    Map.merge(
      %{
        namespace: client.namespace,
        database: client.database,
        endpoint: client.endpoint,
        store: store
      },
      extra
    )

  :telemetry.execute([:surreal_db, :connection, name], %{system_time: System.system_time()}, metadata)
end
```

- [ ] **Step 6: Emit `:disconnected` and route reconnect scheduling through the helper**

Replace the two `{:websocket_closed, reason}` handlers:

```elixir
def handle_info({:websocket_closed, reason}, %State{reconnect?: true} = state) do
  error = %Error{type: :websocket_closed, message: "websocket connection closed", raw: reason}
  fail_all_pending(state.pending, error)
  emit_connection_event(state, :disconnected, %{reason: inspect(reason), will_reconnect?: true})
  state = schedule_reconnect(state)
  {:noreply, %State{state | pending: %{}, setup_complete?: false, socket_pid: nil}}
end

def handle_info({:websocket_closed, reason}, %State{} = state) do
  error = %Error{type: :websocket_closed, message: "websocket connection closed", raw: reason}
  fail_all_pending(state.pending, error)
  emit_connection_event(state, :disconnected, %{reason: inspect(reason), will_reconnect?: false})
  {:stop, :normal, %State{state | pending: %{}}}
end
```

Then update the **connect-failure** branch in `handle_continue(:connect, ...)` to use the helper. Replace its reconnect branch:

```elixir
{:error, reason} ->
  if state.reconnect? do
    state = schedule_reconnect(state)
    {:noreply, %State{state | socket_pid: nil, setup_complete?: false}}
  else
    {:stop, {:websocket_connect_error, reason}, state}
  end
```

(The setup-failed branch in Step 4 already calls `schedule_reconnect/1`.)

- [ ] **Step 7: Run test to verify it passes**

Run: `mix test test/surreal_db/web_socket_test.exs`
Expected: PASS.

- [ ] **Step 8: Thread `store:` from the supervised connection**

In `lib/surreal_db/store/supervisor.ex`, in `connection_children/3`, add `:store` to `connection_opts`:

```elixir
connection_opts =
  resolved
  |> Keyword.get(:websocket_options, [])
  |> Keyword.put(:name, via)
  |> Keyword.put(:reconnect, true)
  |> Keyword.put(:store, store)
```

- [ ] **Step 9: Run the store + websocket suites**

Run: `mix test test/surreal_db/store test/surreal_db/web_socket_test.exs`
Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add lib/surreal_db/web_socket/connection.ex lib/surreal_db/store/supervisor.ex test/surreal_db/web_socket_test.exs
git commit -m "feat: emit [:surreal_db, :connection] lifecycle events

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: Opt-in default logger

**Files:**
- Modify: `lib/surreal_db/telemetry.ex`
- Test: `test/surreal_db/telemetry_test.exs`

- [ ] **Step 1: Write the failing tests**

Add to `test/surreal_db/telemetry_test.exs` (add `import ExUnit.CaptureLog` at the top of the module):

```elixir
describe "attach_default_logger/1" do
  setup do
    on_exit(fn -> Telemetry.detach_default_logger() end)
    :ok
  end

  test "logs a successful query at the configured level" do
    :ok = Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:surreal_db, :query, :stop],
          %{duration: System.convert_time_unit(3, :millisecond, :native)},
          %{method: "query", namespace: "n", database: "d", transport: :http, result: :ok, error: nil}
        )
      end)

    assert log =~ "SurrealDB"
    assert log =~ "query"
    assert log =~ "[info]"
  end

  test "logs failures with the error type and message, never variable values" do
    :ok = Telemetry.attach_default_logger(level: :info)
    error = %Error{type: :transport_error, message: "unauthorized"}

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:surreal_db, :query, :stop],
          %{duration: 0},
          %{method: "query", namespace: "n", database: "d", transport: :http,
            variable_keys: [:password], result: :error, error: error}
        )
      end)

    assert log =~ "transport_error"
    assert log =~ "unauthorized"
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/surreal_db/telemetry_test.exs`
Expected: FAIL — `attach_default_logger/1` undefined.

- [ ] **Step 3: Implement the logger**

Add to `lib/surreal_db/telemetry.ex` (add `require Logger` near the top):

```elixir
@default_logger_id {__MODULE__, :default_logger}

@doc """
Attaches a handler that logs each completed query. Opt-in.

Options:
  * `:level` — log level (default `:debug`).
"""
@spec attach_default_logger(keyword()) :: :ok | {:error, :already_exists}
def attach_default_logger(opts \\ []) do
  level = Keyword.get(opts, :level, :debug)

  :telemetry.attach_many(
    @default_logger_id,
    [[:surreal_db, :query, :stop], [:surreal_db, :query, :exception]],
    &__MODULE__.handle_event/4,
    %{level: level}
  )
end

@doc "Detaches the handler attached by `attach_default_logger/1`."
@spec detach_default_logger() :: :ok | {:error, :not_found}
def detach_default_logger, do: :telemetry.detach(@default_logger_id)

@doc false
def handle_event([:surreal_db, :query, :stop], %{duration: duration}, meta, %{level: level}) do
  Logger.log(level, fn ->
    base = "SurrealDB #{meta.method} ns=#{meta.namespace} db=#{meta.database} transport=#{meta.transport} (#{format_ms(duration)}ms)"

    case meta.result do
      :ok -> base
      :error -> base <> " FAILED #{inspect(error_type(meta.error))}: #{error_message(meta.error)}"
    end
  end)
end

def handle_event([:surreal_db, :query, :exception], %{duration: duration}, meta, %{level: level}) do
  Logger.log(level, fn ->
    "SurrealDB #{meta.method} ns=#{meta.namespace} db=#{meta.database} RAISED #{inspect(meta.kind)}: #{inspect(meta.reason)} (#{format_ms(duration)}ms)"
  end)
end

defp format_ms(duration) do
  (System.convert_time_unit(duration, :native, :microsecond) / 1000) |> Float.round(2)
end

defp error_type(%Error{type: type}), do: type
defp error_type(other), do: other

defp error_message(%Error{message: message}), do: message
defp error_message(other), do: inspect(other)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/surreal_db/telemetry_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/surreal_db/telemetry.ex test/surreal_db/telemetry_test.exs
git commit -m "feat: opt-in SurrealDB.Telemetry default logger

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7: Documentation — moduledoc reference, README, ROADMAP

**Files:**
- Modify: `lib/surreal_db/telemetry.ex` (moduledoc)
- Modify: `README.md`
- Modify: `ROADMAP.md:31-35`

- [ ] **Step 1: Write the full event reference moduledoc**

Replace the placeholder `@moduledoc` in `lib/surreal_db/telemetry.ex` with the canonical reference. Include: the two event families, the measurement and metadata tables (mirroring the spec's "Event reference" section), the metadata-safety contract (query text on by default + `config :hgs_surrealdb_sdk, :telemetry, include_query_text: false`; variable values never emitted; the `error.raw`/`error.details` caveat), an `attach_default_logger/1` example, and a `Telemetry.Metrics`/LiveDashboard example such as:

```elixir
# In your Telemetry supervisor's metrics/0:
[
  Telemetry.Metrics.summary("surreal_db.query.stop.duration",
    unit: {:native, :millisecond}, tags: [:method, :namespace, :result]),
  Telemetry.Metrics.counter("surreal_db.connection.disconnected")
]
```

- [ ] **Step 2: Verify docs compile**

Run: `mix docs` (if `ex_doc` is available) or `mix compile --warnings-as-errors`
Expected: compiles without warnings.

- [ ] **Step 3: Add a README "Telemetry" section**

Add a section to `README.md` (after the configuration sections) covering: the emitted events, attaching a handler with `:telemetry.attach/4`, the `SurrealDB.Telemetry.attach_default_logger/1` one-liner, the `include_query_text` switch and the "variable values are never emitted" guarantee, and the LiveDashboard/`Telemetry.Metrics` example. Point readers to `SurrealDB.Telemetry` for the full reference.

- [ ] **Step 4: Move F1 to Done in ROADMAP.md**

In `ROADMAP.md`, remove the F1 bullet from "## Backlog (nice-to-have)" (lines 33-35) and add it under "## Done", following the style of the R/F entries already there:

```markdown
- **F1 — Telemetry instrumentation.** Emits `:telemetry` start/stop/exception
  spans under `[:surreal_db, :query, …]` around all query/RPC execution (both
  HTTP and WebSocket, including the F2 supervised path), plus
  `[:surreal_db, :connection, …]` lifecycle events. Query text is included by
  default (redactable via `config :hgs_surrealdb_sdk, :telemetry,
  include_query_text: false`); variable values are never emitted. Ships
  `SurrealDB.Telemetry` with `events/0` and an opt-in default logger. See the
  design at `docs/superpowers/specs/2026-06-15-f1-telemetry-instrumentation-design.md`.
```

- [ ] **Step 5: Run the full suite and format check**

Run: `mix test && mix format --check-formatted`
Expected: all tests PASS; formatting clean.

- [ ] **Step 6: Commit**

```bash
git add lib/surreal_db/telemetry.ex README.md ROADMAP.md
git commit -m "docs: document telemetry events and mark F1 done

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Final verification

- [ ] Run `mix test` — full suite passes.
- [ ] Run `mix format --check-formatted` — clean.
- [ ] Run `mix compile --warnings-as-errors` — no warnings.
- [ ] Confirm `SurrealDB.Telemetry.events/0` lists exactly the events emitted across `rpc.ex`, `live.ex`, and `connection.ex` (guards against drift).
- [ ] Spot-check: grep for any remaining `Process.send_after(self(), :reconnect` calls that bypass `schedule_reconnect/1` (there should be none).
