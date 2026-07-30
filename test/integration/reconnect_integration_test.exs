defmodule SurrealDB.ReconnectIntegrationTest do
  use SurrealDB.IntegrationCase

  alias SurrealDB.Error

  @moduletag :integration

  test "socket disconnect fails pending calls and emits telemetry" do
    test_pid = self()
    handler = {:integration_disconnect, System.unique_integer([:positive])}

    :telemetry.attach(
      handler,
      [:surreal_db, :connection, :disconnected],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:disconnected, event, measurements, metadata})
      end,
      nil
    )

    ws_client = await_ws_ready(integration_ws_client())

    on_exit(fn ->
      :telemetry.detach(handler)

      if Process.alive?(ws_client.connection) do
        SurrealDB.WebSocket.stop(ws_client)
      end
    end)

    task = Task.async(fn -> SurrealDB.query(ws_client, "SLEEP 10s; RETURN 1") end)
    state = :sys.get_state(ws_client.connection)
    state.socket_module.close(state.socket_pid)

    assert {:error, %Error{type: :websocket_closed}} = Task.await(task, 5_000)

    assert_receive {:disconnected, [:surreal_db, :connection, :disconnected], _, metadata},
                   5_000

    assert metadata.will_reconnect? == false
  end
end
