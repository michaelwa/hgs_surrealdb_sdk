defmodule SurrealDB.MigrationsTest do
  use ExUnit.Case, async: true

  alias SurrealDB.Client
  alias SurrealDB.Error
  alias SurrealDB.Migrations

  test "install_registry loads schema from priv and uses registry scope" do
    client =
      client_with_adapter(fn request ->
        assert Req.Request.get_header(request, "ns") == ["sdk_meta"]
        assert Req.Request.get_header(request, "db") == ["migration_registry"]
        assert request.body =~ "DEFINE TABLE IF NOT EXISTS sdk_migration SCHEMAFULL"

        ok_response(request, [])
      end)

    assert :ok = Migrations.install_registry(client)
  end

  test "run loads sorted surql files, ignores other files, and uses separate scopes" do
    path =
      tmp_migrations(%{
        "002_second.surql" => "CREATE second;",
        "001_first.surql" => "CREATE first;",
        "notes.txt" => "ignore me"
      })

    calls =
      scripted_calls([
        fn request ->
          assert_registry_request(request)
          assert request.body =~ ~s(filename = "001_first.surql")
          ok_response(request, [])
        end,
        fn request ->
          assert_registry_request(request)
          assert request.body =~ "INSERT INTO sdk_migration"
          assert request.body =~ ~s(filename: "001_first.surql")
          ok_response(request, [%{"status" => "running"}])
        end,
        fn request ->
          assert_target_request(request)
          assert request.body == "CREATE first;"
          ok_response(request, [%{"created" => true}])
        end,
        fn request ->
          assert_registry_request(request)
          assert request.body =~ "status = 'applied'"
          assert request.body =~ ~s(filename = "001_first.surql")
          ok_response(request, [%{"status" => "applied"}])
        end,
        fn request ->
          assert_registry_request(request)
          assert request.body =~ ~s(filename = "002_second.surql")
          ok_response(request, [])
        end,
        fn request ->
          assert_registry_request(request)
          assert request.body =~ "INSERT INTO sdk_migration"
          assert request.body =~ ~s(filename: "002_second.surql")
          ok_response(request, [%{"status" => "running"}])
        end,
        fn request ->
          assert_target_request(request)
          assert request.body == "CREATE second;"
          ok_response(request, [%{"created" => true}])
        end,
        fn request ->
          assert_registry_request(request)
          assert request.body =~ "status = 'applied'"
          assert request.body =~ ~s(filename = "002_second.surql")
          ok_response(request, [%{"status" => "applied"}])
        end
      ])

    assert {:ok, results} =
             calls
             |> client_with_adapter()
             |> Migrations.run(
               path: path,
               target_ns: "app_ns",
               target_db: "app_db",
               sdk_version: "0.1.0"
             )

    assert Enum.map(results, & &1.filename) == ["001_first.surql", "002_second.surql"]
    assert Enum.map(results, & &1.status) == [:applied, :applied]
    assert_no_remaining_calls(calls)
  end

  test "run skips applied migration when checksum matches" do
    contents = "RETURN 1;"
    checksum = checksum(contents)
    path = tmp_migrations(%{"001_done.surql" => contents})

    calls =
      scripted_calls([
        fn request ->
          assert_registry_request(request)

          ok_response(request, [
            %{"status" => "applied", "checksum" => checksum, "filename" => "001_done.surql"}
          ])
        end
      ])

    assert {:ok, [%{filename: "001_done.surql", checksum: ^checksum, status: :skipped}]} =
             calls
             |> client_with_adapter()
             |> Migrations.run(
               path: path,
               target_ns: "app_ns",
               target_db: "app_db",
               sdk_version: "0.1.0"
             )

    assert_no_remaining_calls(calls)
  end

  test "run honors step and version filters" do
    path =
      tmp_migrations(%{
        "20260619000100_first.surql" => "RETURN 1;",
        "20260619000200_second.surql" => "RETURN 2;",
        "20260619000300_third.surql" => "RETURN 3;"
      })

    calls =
      scripted_calls([
        fn request ->
          assert_registry_request(request)
          assert request.body =~ ~s(filename = "20260619000100_first.surql")
          ok_response(request, [])
        end,
        fn request ->
          assert_registry_request(request)
          ok_response(request, [%{"status" => "running"}])
        end,
        fn request ->
          assert_target_request(request)
          assert request.body == "RETURN 1;"
          ok_response(request, [%{"ok" => true}])
        end,
        fn request ->
          assert_registry_request(request)
          ok_response(request, [%{"status" => "applied"}])
        end
      ])

    assert {:ok, [%{filename: "20260619000100_first.surql"}]} =
             calls
             |> client_with_adapter()
             |> Migrations.run(
               path: path,
               target_ns: "app_ns",
               target_db: "app_db",
               sdk_version: "0.1.0",
               step: 1,
               to: "20260619000200"
             )

    assert_no_remaining_calls(calls)
  end

  test "run rejects checksum drift" do
    path = tmp_migrations(%{"001_changed.surql" => "RETURN 2;"})

    calls =
      scripted_calls([
        fn request ->
          assert_registry_request(request)

          ok_response(request, [
            %{
              "status" => "applied",
              "checksum" => "sha256:old",
              "filename" => "001_changed.surql"
            }
          ])
        end
      ])

    assert {:error, %Error{type: :migration_checksum_drift}} =
             calls
             |> client_with_adapter()
             |> Migrations.run(
               path: path,
               target_ns: "app_ns",
               target_db: "app_db",
               sdk_version: "0.1.0"
             )

    assert_no_remaining_calls(calls)
  end

  test "run rejects running migrations" do
    path = tmp_migrations(%{"001_running.surql" => "RETURN 1;"})

    calls =
      scripted_calls([
        fn request ->
          assert_registry_request(request)
          ok_response(request, [%{"status" => "running", "checksum" => checksum("RETURN 1;")}])
        end
      ])

    assert {:error, %Error{type: :migration_already_running}} =
             calls
             |> client_with_adapter()
             |> Migrations.run(
               path: path,
               target_ns: "app_ns",
               target_db: "app_db",
               sdk_version: "0.1.0"
             )

    assert_no_remaining_calls(calls)
  end

  test "run rejects failed migration by default" do
    path = tmp_migrations(%{"001_failed.surql" => "RETURN 1;"})

    calls =
      scripted_calls([
        fn request ->
          assert_registry_request(request)
          ok_response(request, [%{"status" => "failed", "error_message" => "bad"}])
        end
      ])

    assert {:error, %Error{type: :migration_failed_rerun_not_allowed}} =
             calls
             |> client_with_adapter()
             |> Migrations.run(
               path: path,
               target_ns: "app_ns",
               target_db: "app_db",
               sdk_version: "0.1.0"
             )

    assert_no_remaining_calls(calls)
  end

  test "failed migration rerun updates existing row instead of inserting duplicate" do
    path = tmp_migrations(%{"001_retry.surql" => "RETURN 1;"})

    calls =
      scripted_calls([
        fn request ->
          assert_registry_request(request)
          ok_response(request, [%{"status" => "failed", "error_message" => "bad"}])
        end,
        fn request ->
          assert_registry_request(request)
          assert request.body =~ "UPDATE sdk_migration"
          assert request.body =~ "attempt_count += 1"
          refute request.body =~ "INSERT INTO sdk_migration"
          ok_response(request, [%{"status" => "running"}])
        end,
        fn request ->
          assert_target_request(request)
          assert request.body == "RETURN 1;"
          ok_response(request, [%{"ok" => true}])
        end,
        fn request ->
          assert_registry_request(request)
          assert request.body =~ "status = 'applied'"
          ok_response(request, [%{"status" => "applied"}])
        end
      ])

    assert {:ok, [%{filename: "001_retry.surql", status: :applied}]} =
             calls
             |> client_with_adapter()
             |> Migrations.run(
               path: path,
               target_ns: "app_ns",
               target_db: "app_db",
               sdk_version: "0.1.0",
               allow_failed_rerun?: true
             )

    assert_no_remaining_calls(calls)
  end

  test "run marks migration failed after execution error" do
    path = tmp_migrations(%{"001_bad.surql" => "BAD QUERY;"})

    calls =
      scripted_calls([
        fn request ->
          assert_registry_request(request)
          ok_response(request, [])
        end,
        fn request ->
          assert_registry_request(request)
          assert request.body =~ "INSERT INTO sdk_migration"
          ok_response(request, [%{"status" => "running"}])
        end,
        fn request ->
          assert_target_request(request)

          {request,
           Req.Response.new(
             status: 200,
             body: [%{"status" => "ERR", "detail" => "Parse failure"}]
           )}
        end,
        fn request ->
          assert_registry_request(request)
          assert request.body =~ "status = 'failed'"
          assert request.body =~ ~s(error_message = "Parse failure")
          ok_response(request, [%{"status" => "failed"}])
        end
      ])

    assert {:error, %Error{type: :migration_execution_failed}} =
             calls
             |> client_with_adapter()
             |> Migrations.run(
               path: path,
               target_ns: "app_ns",
               target_db: "app_db",
               sdk_version: "0.1.0"
             )

    assert_no_remaining_calls(calls)
  end

  test "run validates required options and rejects websocket clients" do
    %Client{} = client = client_with_adapter(fn request -> ok_response(request, []) end)

    assert {:error, %Error{type: :invalid_migration_options, details: %{missing: missing}}} =
             Migrations.run(client, target_ns: "app_ns")

    assert :path in missing
    assert :target_db in missing
    assert :sdk_version in missing

    websocket = %Client{client | transport: :websocket, connection: self()}

    assert {:error, %Error{type: :unsupported_client_for_migrations}} =
             Migrations.run(websocket,
               path: "unused",
               target_ns: "app_ns",
               target_db: "app_db",
               sdk_version: "0.1.0"
             )
  end

  test "status lists registry rows for the target scope" do
    calls =
      scripted_calls([
        fn request ->
          assert_registry_request(request)
          assert request.body =~ "FROM sdk_migration"
          assert request.body =~ ~s(target_ns = "app_ns")
          assert request.body =~ ~s(target_db = "app_db")
          assert request.body =~ "ORDER BY filename ASC"

          ok_response(request, [
            %{"filename" => "001_first.surql", "status" => "applied"}
          ])
        end
      ])

    assert {:ok, [%{"filename" => "001_first.surql", "status" => "applied"}]} =
             calls
             |> client_with_adapter()
             |> Migrations.status(target_ns: "app_ns", target_db: "app_db")

    assert_no_remaining_calls(calls)
  end

  test "reset deletes registry rows for the target scope only" do
    calls =
      scripted_calls([
        fn request ->
          assert_registry_request(request)
          assert request.body =~ "DELETE sdk_migration"
          assert request.body =~ ~s(target_ns = "app_ns")
          assert request.body =~ ~s(target_db = "app_db")
          ok_response(request, [%{"deleted" => true}])
        end
      ])

    assert {:ok, _result} =
             calls
             |> client_with_adapter()
             |> Migrations.reset(target_ns: "app_ns", target_db: "app_db")

    assert_no_remaining_calls(calls)
  end

  test "rollback removes the latest applied registry rows" do
    calls =
      scripted_calls([
        fn request ->
          assert_registry_request(request)
          assert request.body =~ "status = 'applied'"
          assert request.body =~ "ORDER BY filename DESC"
          assert request.body =~ "LIMIT 2"

          ok_response(request, [
            %{"filename" => "002_second.surql", "status" => "applied"},
            %{"filename" => "001_first.surql", "status" => "applied"}
          ])
        end,
        fn request ->
          assert_registry_request(request)
          assert request.body =~ "DELETE sdk_migration"
          assert request.body =~ ~s(filename IN ["002_second.surql","001_first.surql"])
          ok_response(request, [%{"deleted" => true}])
        end
      ])

    assert {:ok, rows} =
             calls
             |> client_with_adapter()
             |> Migrations.rollback(target_ns: "app_ns", target_db: "app_db", steps: 2)

    assert Enum.map(rows, & &1["filename"]) == ["002_second.surql", "001_first.surql"]
    assert_no_remaining_calls(calls)
  end

  test "rollback runs matching down files before deleting registry rows" do
    down_path = tmp_migrations(%{"001_first.surql" => "REMOVE TABLE first;"})

    calls =
      scripted_calls([
        fn request ->
          assert_registry_request(request)
          ok_response(request, [%{"filename" => "001_first.surql", "status" => "applied"}])
        end,
        fn request ->
          assert_target_request(request)
          assert request.body == "REMOVE TABLE first;"
          ok_response(request, [%{"removed" => true}])
        end,
        fn request ->
          assert_registry_request(request)
          assert request.body =~ "DELETE sdk_migration"
          ok_response(request, [%{"deleted" => true}])
        end
      ])

    assert {:ok, [%{"filename" => "001_first.surql"}]} =
             calls
             |> client_with_adapter()
             |> Migrations.rollback(
               target_ns: "app_ns",
               target_db: "app_db",
               down_path: down_path
             )

    assert_no_remaining_calls(calls)
  end

  test "bang variants raise structured errors" do
    client = client_with_adapter(fn request -> ok_response(request, []) end)

    assert_raise Error, fn ->
      Migrations.run!(client, target_ns: "app_ns")
    end
  end

  defp client_with_adapter(adapter) when is_function(adapter, 1) do
    %Client{
      endpoint: "http://localhost:8000",
      namespace: "original_ns",
      database: "original_db",
      auth: {:basic, %{username: "root", password: "root"}},
      request_options: [adapter: adapter]
    }
  end

  defp client_with_adapter(agent) when is_pid(agent) do
    client_with_adapter(fn request ->
      fun =
        Agent.get_and_update(agent, fn
          [fun | rest] -> {fun, rest}
          [] -> {nil, []}
        end)

      if is_function(fun, 1) do
        fun.(request)
      else
        flunk("unexpected request: #{request.body}")
      end
    end)
  end

  defp scripted_calls(funs) do
    {:ok, agent} = Agent.start_link(fn -> funs end)
    agent
  end

  defp assert_no_remaining_calls(agent) do
    assert Agent.get(agent, & &1) == []
  end

  defp tmp_migrations(files) do
    path =
      Path.join(System.tmp_dir!(), "surrealdb_migrations_#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)

    Enum.each(files, fn {filename, contents} ->
      File.write!(Path.join(path, filename), contents)
    end)

    on_exit(fn -> File.rm_rf!(path) end)

    path
  end

  defp ok_response(request, result) do
    {request, Req.Response.new(status: 200, body: [%{"status" => "OK", "result" => result}])}
  end

  defp assert_registry_request(request) do
    assert Req.Request.get_header(request, "ns") == ["sdk_meta"]
    assert Req.Request.get_header(request, "db") == ["migration_registry"]
  end

  defp assert_target_request(request) do
    assert Req.Request.get_header(request, "ns") == ["app_ns"]
    assert Req.Request.get_header(request, "db") == ["app_db"]
  end

  defp checksum(contents) do
    hash = :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
    "sha256:" <> hash
  end
end
