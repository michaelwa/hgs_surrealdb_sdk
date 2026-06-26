defmodule Mix.Tasks.Surreal.MigrationTaskHelpersTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Surreal.MigrationTaskHelpers, as: Helpers
  alias SurrealDB.Client

  defmodule ExampleStore do
    def config do
      [
        endpoint: "http://store.example:8000",
        namespace: "store_ns",
        database: "store_db",
        username: "store_user",
        password: "store_pass",
        repo_path: "priv/store_repo"
      ]
    end
  end

  defmodule OtherStore do
    def config do
      [
        endpoint: "http://other.example:8000",
        namespace: "other_ns",
        database: "other_db",
        username: "other_user",
        password: "other_pass"
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

  describe "store auto-detection via :surrealdb_stores" do
    setup do
      app = Mix.Project.config()[:app]
      previous = Application.get_env(app, :surrealdb_stores)

      on_exit(fn ->
        if previous do
          Application.put_env(app, :surrealdb_stores, previous)
        else
          Application.delete_env(app, :surrealdb_stores)
        end
      end)

      %{app: app}
    end

    test "auto-detects the single registered store when --store is omitted", %{app: app} do
      Application.put_env(app, :surrealdb_stores, [__MODULE__.ExampleStore])

      opts = Helpers.parse!([])
      client = Helpers.build_client!(opts)

      assert client.namespace == "store_ns"
      assert client.database == "store_db"
    end

    test "raises when no store is registered and no scope is given", %{app: app} do
      Application.put_env(app, :surrealdb_stores, [])

      opts = Helpers.parse!([])

      assert_raise Mix.Error, ~r/Could not determine a target namespace\/database/, fn ->
        Helpers.build_client!(opts)
      end
    end

    test "raises on ambiguous multiple stores without --store", %{app: app} do
      Application.put_env(app, :surrealdb_stores, [__MODULE__.ExampleStore, __MODULE__.OtherStore])

      opts = Helpers.parse!([])

      assert_raise Mix.Error, ~r/Multiple SurrealDB stores are registered/, fn ->
        Helpers.build_client!(opts)
      end
    end

    test "explicit --namespace/--database bypasses ambiguous multiple stores", %{app: app} do
      Application.put_env(app, :surrealdb_stores, [__MODULE__.ExampleStore, __MODULE__.OtherStore])

      opts = Helpers.parse!(["--namespace", "manual_ns", "--database", "manual_db"])
      client = Helpers.build_client!(opts)

      assert client.namespace == "manual_ns"
      assert client.database == "manual_db"
    end
  end

  test "repo_path defaults to priv/surreal_repo" do
    assert Helpers.repo_path([]) == "priv/surreal_repo"
  end

  test "repo_path honors --repo-path override" do
    assert Helpers.repo_path(repo_path: "priv/custom") == "priv/custom"
  end

  test "repo_path reads store config" do
    opts = Helpers.parse!(["--store", inspect(__MODULE__.ExampleStore)])

    assert Helpers.repo_path(opts) == "priv/store_repo"
  end

  test "migration_paths derives repo migrations directory by default" do
    assert Helpers.migration_paths([]) == "priv/surreal_repo/migrations"
    assert Helpers.migration_paths(repo_path: "priv/custom") == "priv/custom/migrations"
  end

  test "explicit path overrides repo-derived migrations directory" do
    assert Helpers.migration_paths(path: "priv/legacy") == "priv/legacy"
  end

  test "migration_opts defaults path to repo migrations directory" do
    opts = Helpers.parse!(["--namespace", "app_ns", "--database", "app_db"])
    client = Helpers.build_client!(opts)

    migration_opts = Helpers.migration_opts(client, opts)

    assert migration_opts[:path] == "priv/surreal_repo/migrations"
    refute Keyword.has_key?(migration_opts, :target_ns)
    refute Keyword.has_key?(migration_opts, :target_db)
    refute Keyword.has_key?(migration_opts, :registry_ns)
    refute Keyword.has_key?(migration_opts, :registry_db)
    refute Keyword.has_key?(migration_opts, :down_path)
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

    target_opts = Helpers.target_opts(client, opts)

    assert target_opts[:path] == "priv/surreal_repo/migrations"
    assert target_opts[:steps] == 9_223_372_036_854_775_807
    refute Keyword.has_key?(target_opts, :target_ns)
    refute Keyword.has_key?(target_opts, :target_db)
    refute Keyword.has_key?(target_opts, :registry_ns)
    refute Keyword.has_key?(target_opts, :registry_db)
    refute Keyword.has_key?(target_opts, :down_path)
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

  test "drop_database! reports existing database as dropped" do
    client =
      client_with_adapter(fn request ->
        cond do
          request.body =~ "INFO FOR NS" ->
            assert request.body =~ "USE NS app_ns"

            {request,
             Req.Response.new(
               status: 200,
               body: [
                 %{"status" => "OK", "result" => nil},
                 %{
                   "status" => "OK",
                   "result" => %{"databases" => %{"app_db" => "DEFINE DATABASE app_db"}}
                 }
               ]
             )}

          request.body =~ "REMOVE DATABASE IF EXISTS app_db" ->
            assert request.body =~ "USE NS app_ns"
            ok_response(request, [])

          true ->
            flunk("unexpected request body: #{request.body}")
        end
      end)

    assert {"app_ns", "app_db", true} =
             Helpers.drop_database!(client, namespace: "app_ns", database: "app_db")
  end

  test "drop_database! reports a missing database as not existing" do
    client =
      client_with_adapter(fn request ->
        cond do
          request.body =~ "INFO FOR NS" ->
            {request,
             Req.Response.new(
               status: 200,
               body: [
                 %{"status" => "OK", "result" => nil},
                 %{"status" => "OK", "result" => %{"databases" => %{}}}
               ]
             )}

          request.body =~ "REMOVE DATABASE IF EXISTS app_db" ->
            ok_response(request, [])

          true ->
            flunk("unexpected request body: #{request.body}")
        end
      end)

    assert {"app_ns", "app_db", false} =
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
