defmodule SurrealDB.MigrationsIntegrationTest do
  use SurrealDB.IntegrationCase

  alias SurrealDB.{Error, Migrations, QueryResult}

  @moduletag :integration

  test "runs, skips, detects checksum drift, and rolls back a live migration" do
    client = integration_client()
    suffix = integration_scope()
    table = "#{suffix}_migration_people"
    filename = "#{suffix}_create_people.surql"
    registry_ns = "#{suffix}_registry_ns"
    registry_db = "#{suffix}_registry_db"
    path = Path.join(System.tmp_dir!(), "hgs_surrealdb_sdk_#{suffix}")
    File.mkdir_p!(path)

    contents = """
    -- migrate:up
    DEFINE TABLE #{table} SCHEMALESS;

    -- migrate:down
    REMOVE TABLE #{table};
    """

    File.write!(Path.join(path, filename), contents)

    assert {:ok, %QueryResult{}} =
             SurrealDB.query(client, "DEFINE NAMESPACE IF NOT EXISTS #{registry_ns};")

    registry_client = %{client | namespace: registry_ns, database: registry_db}

    assert {:ok, %QueryResult{}} =
             SurrealDB.query(registry_client, "DEFINE DATABASE IF NOT EXISTS #{registry_db};")

    on_exit(fn ->
      File.rm_rf(path)

      assert {:ok, %QueryResult{}} =
               SurrealDB.query(
                 registry_client,
                 "DELETE schema_migrations WHERE filename = $filename;",
                 %{
                   filename: filename
                 }
               )

      assert {:ok, %QueryResult{}} = SurrealDB.query(client, "REMOVE TABLE IF EXISTS #{table};")

      assert {:ok, %QueryResult{}} =
               SurrealDB.query(registry_client, "REMOVE DATABASE IF EXISTS #{registry_db};")

      assert {:ok, %QueryResult{}} =
               SurrealDB.query(client, "REMOVE NAMESPACE IF EXISTS #{registry_ns};")
    end)

    registry_opts = [registry_ns: registry_ns, registry_db: registry_db]

    assert :ok = Migrations.install_registry(client, registry_opts)

    assert {:ok, [%{filename: ^filename, status: :applied}]} =
             Migrations.run(client, [path: path, sdk_version: "0.1.0"] ++ registry_opts)

    assert {:ok, [%{filename: ^filename, status: :skipped}]} =
             Migrations.run(client, [path: path, sdk_version: "0.1.0"] ++ registry_opts)

    assert {:ok, [%{"filename" => ^filename, "status" => "applied"}]} =
             Migrations.status(client, registry_opts)

    assert {:ok, %QueryResult{results: [%{"tables" => tables}]}} =
             SurrealDB.query(client, "INFO FOR DB;")

    assert Map.has_key?(tables, table)
    refute Map.has_key?(tables, "schema_migrations")

    assert {:ok, %QueryResult{results: [%{"tables" => registry_tables}]}} =
             SurrealDB.query(registry_client, "INFO FOR DB;")

    assert Map.has_key?(registry_tables, "schema_migrations")

    File.write!(Path.join(path, filename), contents <> "\n-- checksum drift\n")

    assert {:error, %Error{type: :migration_checksum_drift}} =
             Migrations.run(client, [path: path, sdk_version: "0.1.0"] ++ registry_opts)

    File.write!(Path.join(path, filename), contents)

    assert {:ok, [%{filename: ^filename, reverted?: true}]} =
             Migrations.rollback(client, [path: path, steps: 1] ++ registry_opts)
  end

  test "allows only one concurrent runner to claim a migration" do
    client = integration_client()
    suffix = integration_scope()
    table = "#{suffix}_concurrent_people"
    filename = "#{suffix}_concurrent.surql"
    registry_ns = "#{suffix}_concurrent_registry_ns"
    registry_db = "#{suffix}_concurrent_registry_db"
    path = Path.join(System.tmp_dir!(), "hgs_surrealdb_sdk_#{suffix}")
    File.mkdir_p!(path)

    File.write!(
      Path.join(path, filename),
      "-- migrate:up\nDEFINE TABLE IF NOT EXISTS #{table} SCHEMALESS;"
    )

    assert {:ok, %QueryResult{}} =
             SurrealDB.query(client, "DEFINE NAMESPACE IF NOT EXISTS #{registry_ns};")

    registry_client = %{client | namespace: registry_ns, database: registry_db}

    assert {:ok, %QueryResult{}} =
             SurrealDB.query(registry_client, "DEFINE DATABASE IF NOT EXISTS #{registry_db};")

    registry_opts = [registry_ns: registry_ns, registry_db: registry_db]

    on_exit(fn ->
      File.rm_rf(path)
      _ = SurrealDB.query(client, "REMOVE TABLE IF EXISTS #{table};")
      _ = SurrealDB.query(registry_client, "REMOVE DATABASE IF EXISTS #{registry_db};")
      _ = SurrealDB.query(client, "REMOVE NAMESPACE IF EXISTS #{registry_ns};")
    end)

    run = fn ->
      Migrations.run(client, [path: path, sdk_version: "0.1.0"] ++ registry_opts)
    end

    results = [Task.async(run), Task.async(run)] |> Task.await_many(15_000)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, _}, &1)) == 1

    assert {:error, %Error{type: error_type}} = Enum.find(results, &match?({:error, _}, &1))
    assert error_type in [:migration_already_running, :migration_claim_conflict]
  end
end
