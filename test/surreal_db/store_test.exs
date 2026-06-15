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

  test "client/0 returns not_connected for a websocket store with no live connection" do
    ws_client = %Client{
      endpoint: "ws://localhost:8000/rpc",
      namespace: "ns",
      database: "db",
      transport: :websocket
    }

    :persistent_term.put({SurrealDB.Store, HttpStore}, ws_client)

    assert {:error, %Error{type: :not_connected}} = HttpStore.client()
  end

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
