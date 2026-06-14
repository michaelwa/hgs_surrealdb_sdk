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
