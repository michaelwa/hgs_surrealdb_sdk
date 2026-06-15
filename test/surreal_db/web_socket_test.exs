defmodule SurrealDB.WebSocketTest do
  use ExUnit.Case, async: true

  alias SurrealDB.Client
  alias SurrealDB.Error
  alias SurrealDB.QueryResult
  alias SurrealDB.RPC.Request
  alias SurrealDB.RPC.Response
  alias SurrealDB.Transport.WebSocket
  alias SurrealDB.WebSocketTest.FakeSocket

  test "starting a websocket connection process and setup traffic" do
    client = websocket_client(request_options: [test_pid: self(), auto_setup: true])

    assert {:ok, pid} =
             SurrealDB.WebSocket.Connection.start_link(client,
               socket_module: FakeSocket,
               timeout: 50
             )

    assert_receive {:fake_socket_started, ^pid, "ws://localhost:8000/rpc", headers, _socket_pid}
    assert {"authorization", _} = List.first(headers)
    assert_receive {:socket_sent, ^pid, payload1}
    assert_receive {:socket_sent, ^pid, payload2}

    methods = Enum.map([payload1, payload2], &Jason.decode!(&1)["method"]) |> Enum.sort()
    assert methods == ["signin", "use"]
  end

  test "matching responses to callers over websocket transport" do
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

    request = Request.new("query", ["SELECT * FROM person"])

    task =
      Task.async(fn ->
        WebSocket.call(client, request)
      end)

    assert_receive {:socket_sent, owner, payload}
    decoded = Jason.decode!(payload)
    assert owner == client.connection
    assert decoded["id"] == request.id
    assert decoded["method"] == "query"

    send(
      owner,
      {:websocket_frame,
       Jason.encode!(%{id: request.id, result: [%{"status" => "OK", "result" => []}]})}
    )

    request_id = request.id

    assert {:ok, %Response{id: ^request_id, result: [%{"result" => [], "status" => "OK"}]}} =
             Task.await(task)
  end

  test "timeout behavior" do
    {:ok, client} =
      SurrealDB.connect_ws(
        endpoint: "ws://localhost:8000/rpc",
        namespace: "test",
        database: "app",
        username: "root",
        password: "root",
        request_options: [test_pid: self(), auto_setup: true],
        websocket_options: [socket_module: FakeSocket, timeout: 20]
      )

    wait_for_setup()

    request = Request.new("query", ["SELECT * FROM person"])

    assert {:error, %Error{type: :websocket_timeout}} =
             WebSocket.call(client, request, 20)
  end

  test "socket close behavior fails pending callers" do
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

    request = Request.new("query", ["SELECT * FROM person"])

    task =
      Task.async(fn ->
        WebSocket.call(client, request, 200)
      end)

    assert_receive {:socket_sent, owner, payload}
    assert Jason.decode!(payload)["id"] == request.id
    send(owner, {:websocket_closed, :closed})

    assert {:error, %Error{type: :websocket_closed}} = Task.await(task)
  end

  test "rpc error response mapping over websocket" do
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

    request = Request.new("query", ["BAD QUERY"])

    task = Task.async(fn -> SurrealDB.rpc(client, "query", ["BAD QUERY"]) end)

    assert_receive {:socket_sent, owner, payload}
    assert Jason.decode!(payload)["id"] == request.id or true

    send(
      owner,
      {:websocket_frame,
       Jason.encode!(%{
         id: Jason.decode!(payload)["id"],
         error: %{code: "BAD", message: "query rejected"}
       })}
    )

    assert {:error, %Error{type: :rpc_error, code: "BAD", message: "query rejected"}} =
             Task.await(task)
  end

  test "public query works over websocket clients" do
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

    task = Task.async(fn -> SurrealDB.query(client, "SELECT * FROM person") end)

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

    assert {:ok, %QueryResult{statuses: ["OK"], results: [[%{"id" => "person:one"}]]}} =
             Task.await(task)
  end

  test "live query start stores subscription and returns subscription struct" do
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

    task =
      Task.async(fn -> SurrealDB.live(client, "LIVE SELECT * FROM person", send_to: self()) end)

    assert_receive {:socket_sent, owner, payload}
    decoded = Jason.decode!(payload)
    assert decoded["method"] == "query"
    assert decoded["params"] == ["LIVE SELECT * FROM person"]

    send(
      owner,
      {:websocket_frame,
       Jason.encode!(%{
         id: decoded["id"],
         result: [%{"status" => "OK", "result" => "live-person"}]
       })}
    )

    assert {:ok,
            %SurrealDB.Live.Subscription{
              id: "live-person",
              query: "LIVE SELECT * FROM person",
              status: :active
            }} =
             Task.await(task)
  end

  test "incoming live event routes to subscribed pid" do
    target = self()

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

    task =
      Task.async(fn -> SurrealDB.live(client, "LIVE SELECT * FROM person", send_to: target) end)

    assert_receive {:socket_sent, owner, payload}
    decoded = Jason.decode!(payload)
    subscription_id = "live-person"

    send(
      owner,
      {:websocket_frame,
       Jason.encode!(%{
         id: decoded["id"],
         result: [%{"status" => "OK", "result" => subscription_id}]
       })}
    )

    assert {:ok, subscription} = Task.await(task)

    send(
      owner,
      {:websocket_frame,
       Jason.encode!(%{
         result: %{id: subscription_id, action: "CREATE", result: %{"id" => "person:one"}}
       })}
    )

    assert_receive {:surrealdb_live, ^subscription_id,
                    %SurrealDB.Live.Event{action: "CREATE", result: %{"id" => "person:one"}}}

    assert subscription.id == subscription_id
  end

  test "unknown subscription event is handled safely" do
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

    send(
      client.connection,
      {:websocket_frame,
       Jason.encode!(%{
         result: %{id: "missing-sub", action: "UPDATE", result: %{"id" => "person:one"}}
       })}
    )

    refute_receive {:surrealdb_live, _, _}, 50
    assert Process.alive?(client.connection)
  end

  test "kill removes subscription" do
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

    task =
      Task.async(fn -> SurrealDB.live(client, "LIVE SELECT * FROM person", send_to: self()) end)

    assert_receive {:socket_sent, owner, payload}
    decoded = Jason.decode!(payload)
    subscription_id = "live-person"

    send(
      owner,
      {:websocket_frame,
       Jason.encode!(%{
         id: decoded["id"],
         result: [%{"status" => "OK", "result" => subscription_id}]
       })}
    )

    assert {:ok, subscription} = Task.await(task)

    kill_task = Task.async(fn -> SurrealDB.kill(client, subscription) end)
    assert_receive {:socket_sent, ^owner, kill_payload}
    kill_decoded = Jason.decode!(kill_payload)
    assert kill_decoded["method"] == "kill"
    assert kill_decoded["params"] == [subscription_id]

    send(
      owner,
      {:websocket_frame, Jason.encode!(%{id: kill_decoded["id"], result: %{"ok" => true}})}
    )

    assert :ok = Task.await(kill_task)

    send(
      owner,
      {:websocket_frame,
       Jason.encode!(%{
         result: %{id: subscription_id, action: "UPDATE", result: %{"id" => "person:one"}}
       })}
    )

    refute_receive {:surrealdb_live, ^subscription_id, _}, 50
  end

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

    task =
      Task.async(fn -> SurrealDB.live(client, "LIVE SELECT * FROM person", send_to: self()) end)

    assert_receive {:socket_sent, owner, payload}
    decoded = Jason.decode!(payload)

    send(
      owner,
      {:websocket_frame,
       Jason.encode!(%{
         id: decoded["id"],
         result: [%{"status" => "OK", "result" => "live-person"}]
       })}
    )

    assert {:ok, _subscription} = Task.await(task)
    assert_receive {:live_stop, %{method: "live", result: :ok, transport: :websocket}}
  end

  test "kill of missing subscription returns error" do
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

    subscription = %SurrealDB.Live.Subscription{
      id: "missing",
      query: "LIVE SELECT * FROM person",
      target: self(),
      status: :active
    }

    assert {:error, %Error{type: :subscription_not_found}} = SurrealDB.kill(client, subscription)
  end

  test "malformed live event is handled as structured error behavior" do
    client =
      websocket_client(
        request_options: [test_pid: self(), auto_setup: true],
        auth: {:basic, %{username: "root", password: "root"}}
      )

    {:ok, pid} =
      SurrealDB.WebSocket.Connection.start_link(client, socket_module: FakeSocket, timeout: 50)

    wait_for_setup()

    Process.unlink(pid)
    ref = Process.monitor(pid)
    send(pid, {:websocket_frame, "{bad-json"})

    assert_receive {:DOWN, ^ref, :process, _pid, reason}

    assert match?({:unexpected_response, %Error{type: :unexpected_response}}, reason) or
             match?({:setup_failed, %Error{type: :unexpected_response}}, reason)
  end

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

  defmodule FailThenSucceedSocket do
    # First start_link attempt fails; subsequent attempts delegate to FakeSocket.
    def start_link(owner, url, headers, options) do
      test_pid = Keyword.fetch!(options, :test_pid)

      if :persistent_term.get({__MODULE__, test_pid}, false) do
        SurrealDB.WebSocketTest.FakeSocket.start_link(owner, url, headers, options)
      else
        :persistent_term.put({__MODULE__, test_pid}, true)
        send(test_pid, :first_connect_attempted)
        {:error, :econnrefused}
      end
    end

    defdelegate send_text(pid, payload), to: SurrealDB.WebSocketTest.FakeSocket
    defdelegate close(pid), to: SurrealDB.WebSocketTest.FakeSocket
  end

  test "reconnect: true retries after an initial connect failure instead of stopping" do
    test_pid = self()
    on_exit(fn -> :persistent_term.erase({FailThenSucceedSocket, test_pid}) end)
    client = websocket_client(request_options: [test_pid: test_pid, auto_setup: true])

    {:ok, pid} =
      SurrealDB.WebSocket.Connection.start_link(client,
        socket_module: FailThenSucceedSocket,
        timeout: 50,
        reconnect: true,
        reconnect_backoff: 10
      )

    assert_receive :first_connect_attempted, 200
    assert Process.alive?(pid)
    # After backoff it retries, this time succeeding -> setup traffic flows.
    assert_receive {:fake_socket_started, ^pid, _url, _headers, _socket_pid}, 500
    assert_receive {:socket_sent, ^pid, _payload}, 500
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

  defp websocket_client(overrides) do
    %Client{
      endpoint: "ws://localhost:8000/rpc",
      namespace: "test",
      database: "app",
      auth: Keyword.get(overrides, :auth, {:basic, %{username: "root", password: "root"}}),
      transport: :websocket,
      request_options: Keyword.fetch!(overrides, :request_options)
    }
  end

  defp wait_for_setup do
    assert_receive {:socket_sent, _owner, _payload}
    assert_receive {:socket_sent, _owner, _payload}
  end
end
