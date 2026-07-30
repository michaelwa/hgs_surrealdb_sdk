defmodule SurrealDB.WebSocketIntegrationTest do
  use SurrealDB.IntegrationCase

  alias SurrealDB.{Error, QueryResult}

  @moduletag :integration

  setup do
    test_pid = self()
    handler = {:integration_ws, System.unique_integer([:positive])}

    :telemetry.attach(
      handler,
      [:surreal_db, :connection, :connected],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:connection_event, event, measurements, metadata})
      end,
      nil
    )

    ws_client = integration_ws_client()

    on_exit(fn ->
      :telemetry.detach(handler)
      if Process.alive?(ws_client.connection), do: SurrealDB.WebSocket.stop(ws_client)
    end)

    assert_receive {:connection_event, [:surreal_db, :connection, :connected], _, _}, 5_000
    %{client: integration_client(), ws_client: ws_client}
  end

  test "query and RPC errors work over a real WebSocket", %{ws_client: client} do
    assert {:ok, %QueryResult{results: [1]}} = SurrealDB.query(client, "RETURN 1")

    assert {:error, %Error{type: :surreal_error}} =
             SurrealDB.query(client, ~s(THROW "websocket integration error"))
  end

  test "closing the socket fails a pending caller with a structured error", %{ws_client: client} do
    task = Task.async(fn -> SurrealDB.query(client, "SLEEP 10s; RETURN 1") end)
    state = :sys.get_state(client.connection)
    state.socket_module.close(state.socket_pid)

    assert {:error, %Error{type: :websocket_closed}} = Task.await(task, 5_000)
  end
end
