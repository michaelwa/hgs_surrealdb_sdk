defmodule SurrealDB.TelemetryTest do
  use ExUnit.Case, async: true

  alias SurrealDB.Client
  alias SurrealDB.Error
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

      assert Telemetry.stop_metadata(start, {:ok, :anything}) == %{
               method: "query",
               result: :ok,
               error: nil
             }

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
end
