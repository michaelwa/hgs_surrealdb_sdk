defmodule SurrealDB.LiveQueryIntegrationTest do
  use SurrealDB.IntegrationCase

  alias SurrealDB.QueryResult

  @moduletag :integration

  setup do
    client = integration_client()
    table = integration_table("live_people")

    assert {:ok, %QueryResult{}} = SurrealDB.query(client, "DEFINE TABLE #{table} SCHEMALESS;")
    %{client: client, table: table, ws_client: await_ws_ready(integration_ws_client())}
  end

  test "live query delivers create events and stops after kill", %{
    client: client,
    table: table,
    ws_client: ws_client
  } do
    assert {:ok, subscription} =
             SurrealDB.live(ws_client, "LIVE SELECT * FROM #{table}", send_to: self())

    assert {:ok, _} = SurrealDB.create(client, "#{table}:one", %{name: "event"})

    assert_receive {:surrealdb_live, subscription_id, %SurrealDB.Live.Event{action: "CREATE"}},
                   5_000

    assert subscription_id == subscription.id
    assert :ok = SurrealDB.kill(ws_client, subscription)
    assert {:ok, _} = SurrealDB.create(client, "#{table}:two", %{name: "after-kill"})
    refute_receive {:surrealdb_live, ^subscription_id, _}, 300
  end
end
