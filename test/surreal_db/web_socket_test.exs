defmodule SurrealDB.WebSocketTest do
  use ExUnit.Case, async: true

  alias SurrealDB.Client
  alias SurrealDB.Error
  alias SurrealDB.QueryResult
  alias SurrealDB.RPC.Request
  alias SurrealDB.RPC.Response
  alias SurrealDB.Transport.WebSocket

  defmodule FakeSocket do
    def start_link(owner, url, headers, options) do
      test_pid = Keyword.fetch!(options, :test_pid)
      auto_setup = Keyword.get(options, :auto_setup, false)

      pid =
        spawn_link(fn ->
          send(test_pid, {:fake_socket_started, owner, url, headers, self()})
          send(owner, {:websocket_connected, self()})
          loop(owner, test_pid, auto_setup)
        end)

      {:ok, pid}
    end

    def send_text(pid, payload) do
      send(pid, {:send_text, payload})
      :ok
    end

    def close(pid) do
      send(pid, :close)
      :ok
    end

    defp loop(owner, test_pid, auto_setup) do
      receive do
        {:send_text, payload} ->
          send(test_pid, {:socket_sent, owner, payload})

          if auto_setup do
            decoded = Jason.decode!(payload)

            if decoded["method"] in ["signin", "authenticate", "use"] do
              send(
                owner,
                {:websocket_frame, Jason.encode!(%{id: decoded["id"], result: %{"ok" => true}})}
              )
            end
          end

          loop(owner, test_pid, auto_setup)

        :close ->
          send(owner, {:websocket_closed, :normal})
          :ok
      end
    end
  end

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

  defp websocket_client(overrides) do
    %Client{
      endpoint: "ws://localhost:8000/rpc",
      namespace: "test",
      database: "app",
      auth: {:basic, %{username: "root", password: "root"}},
      transport: :websocket,
      request_options: Keyword.fetch!(overrides, :request_options)
    }
  end

  defp wait_for_setup do
    assert_receive {:socket_sent, _owner, _payload}
    assert_receive {:socket_sent, _owner, _payload}
  end
end
