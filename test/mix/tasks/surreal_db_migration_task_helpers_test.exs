defmodule Mix.Tasks.SurrealDb.MigrationTaskHelpersTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.SurrealDb.MigrationTaskHelpers, as: Helpers
  alias SurrealDB.Client

  defmodule ExampleStore do
    def config do
      [
        endpoint: "http://store.example:8000",
        namespace: "store_ns",
        database: "store_db",
        username: "store_user",
        password: "store_pass"
      ]
    end
  end

  test "build_client! reads generated store config and allows CLI overrides" do
    opts =
      Helpers.parse!([
        "--store",
        inspect(__MODULE__.ExampleStore),
        "--database",
        "override_db"
      ])

    client = Helpers.build_client!(opts)

    assert client.endpoint == "http://store.example:8000"
    assert client.namespace == "store_ns"
    assert client.database == "override_db"
    assert client.auth == {:basic, %{username: "store_user", password: "store_pass"}}
    assert client.transport == :http
  end

  test "build_client! raises a clear error when no store or scope is given" do
    opts = Helpers.parse!([])

    assert_raise Mix.Error, ~r/Could not determine a target namespace\/database/, fn ->
      Helpers.build_client!(opts)
    end
  end

  test "migration_opts defaults path and target to the client scope" do
    opts = Helpers.parse!(["--namespace", "app_ns", "--database", "app_db"])
    client = Helpers.build_client!(opts)

    migration_opts = Helpers.migration_opts(client, opts)

    assert migration_opts[:path] == "priv/surrealdb_migrations"
    assert migration_opts[:target_ns] == "app_ns"
    assert migration_opts[:target_db] == "app_db"
    assert is_binary(migration_opts[:sdk_version])
  end

  test "migration_opts accepts ecto-style migration flags" do
    opts =
      Helpers.parse!([
        "--namespace",
        "app_ns",
        "--database",
        "app_db",
        "--migrations-path",
        "priv/a",
        "--migrations-path",
        "priv/b",
        "-n",
        "2",
        "--to",
        "20260619000000"
      ])

    client = Helpers.build_client!(opts)
    migration_opts = Helpers.migration_opts(client, opts)

    assert migration_opts[:path] == ["priv/a", "priv/b"]
    assert migration_opts[:step] == 2
    assert migration_opts[:to] == "20260619000000"
  end

  test "target_opts maps rollback --all to a large step count" do
    opts = Helpers.parse!(["--namespace", "app_ns", "--database", "app_db", "--all"])
    client = Helpers.build_client!(opts)

    assert Helpers.target_opts(client, opts)[:steps] == 9_223_372_036_854_775_807
  end

  test "create_database! emits namespace and database DDL" do
    client =
      client_with_adapter(fn request ->
        assert request.body =~ "DEFINE NAMESPACE IF NOT EXISTS app_ns"
        assert request.body =~ "USE NS app_ns"
        assert request.body =~ "DEFINE DATABASE IF NOT EXISTS app_db"
        ok_response(request, [])
      end)

    assert {"app_ns", "app_db"} =
             Helpers.create_database!(client, namespace: "app_ns", database: "app_db")
  end

  test "drop_database! emits database removal DDL" do
    client =
      client_with_adapter(fn request ->
        assert request.body =~ "USE NS app_ns"
        assert request.body =~ "REMOVE DATABASE IF EXISTS app_db"
        ok_response(request, [])
      end)

    assert {"app_ns", "app_db"} =
             Helpers.drop_database!(client, namespace: "app_ns", database: "app_db")
  end

  test "quote_identifier! rejects unsafe names" do
    assert_raise Mix.Error, fn ->
      Helpers.quote_identifier!("app; REMOVE DATABASE prod", "namespace")
    end
  end

  defp client_with_adapter(adapter) do
    %Client{
      endpoint: "http://localhost:8000",
      namespace: "original_ns",
      database: "original_db",
      auth: {:basic, %{username: "root", password: "root"}},
      request_options: [adapter: adapter]
    }
  end

  defp ok_response(request, result) do
    {request, Req.Response.new(status: 200, body: [%{"status" => "OK", "result" => result}])}
  end
end
