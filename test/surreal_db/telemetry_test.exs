defmodule SurrealDB.TelemetryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

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

      assert meta.variable_keys == [:data, :id]
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

    test "captures a raw (non-Error) error term on failure" do
      start = %{method: "query"}
      stop = Telemetry.stop_metadata(start, {:error, :timeout})
      assert stop.result == :error
      assert stop.error == :timeout
    end
  end

  describe "span/4" do
    setup do
      client = %Client{endpoint: "http://x", namespace: "n", database: "d", transport: :http}

      events = [
        [:surreal_db, :query, :start],
        [:surreal_db, :query, :stop],
        [:surreal_db, :query, :exception]
      ]

      test_pid = self()
      handler_id = {:test, System.unique_integer()}

      :telemetry.attach_many(
        handler_id,
        events,
        fn event, measurements, meta, _ ->
          send(test_pid, {:telemetry, event, measurements, meta})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      %{client: client}
    end

    test "emits start then stop on success", %{client: client} do
      result = Telemetry.span(client, "query", [query: "SELECT 1"], fn -> {:ok, :resp} end)

      assert result == {:ok, :resp}

      assert_receive {:telemetry, [:surreal_db, :query, :start], %{system_time: _},
                      %{method: "query"}}

      assert_receive {:telemetry, [:surreal_db, :query, :stop], %{duration: _},
                      %{result: :ok, error: nil}}
    end

    test "stop carries the error on failure", %{client: client} do
      error = %Error{type: :transport_error, message: "boom"}
      assert Telemetry.span(client, "query", [], fn -> {:error, error} end) == {:error, error}

      assert_receive {:telemetry, [:surreal_db, :query, :stop], _,
                      %{result: :error, error: ^error}}
    end

    test "raises propagate and emit an exception event", %{client: client} do
      assert_raise RuntimeError, "kaboom", fn ->
        Telemetry.span(client, "query", [], fn -> raise "kaboom" end)
      end

      assert_receive {:telemetry, [:surreal_db, :query, :exception], %{duration: _},
                      %{kind: :error, reason: %RuntimeError{}}}
    end
  end

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
            %{
              method: "query",
              namespace: "n",
              database: "d",
              transport: :http,
              result: :ok,
              error: nil
            }
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
            %{
              method: "query",
              namespace: "n",
              database: "d",
              transport: :http,
              variable_keys: [:password],
              result: :error,
              error: error
            }
          )
        end)

      assert log =~ "transport_error"
      assert log =~ "unauthorized"
    end
  end

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

      assert_receive {:telemetry, [:surreal_db, :query, :start],
                      %{method: "query", query: "SELECT * FROM person", transport: :http}}

      assert_receive {:telemetry, [:surreal_db, :query, :stop], %{result: :ok}}
    end

    test "a transport failure emits a stop with result :error" do
      client = %Client{
        ok_client()
        | request_options: [
            adapter: fn request ->
              {request, Req.Response.new(status: 401, body: ~s({"error":"nope"}))}
            end
          ]
      }

      assert {:error, %Error{}} = SurrealDB.rpc(client, "query", ["SELECT 1"])

      assert_receive {:telemetry, [:surreal_db, :query, :stop],
                      %{result: :error, error: %Error{}}}
    end
  end
end
