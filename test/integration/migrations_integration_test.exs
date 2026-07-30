defmodule SurrealDB.MigrationsIntegrationTest do
  use SurrealDB.IntegrationCase

  alias SurrealDB.{Error, Migrations, QueryResult}

  @moduletag :integration

  test "runs, skips, detects checksum drift, and rolls back a live migration" do
    client = integration_client()
    suffix = integration_scope()
    table = "#{suffix}_migration_people"
    filename = "#{suffix}_create_people.surql"
    path = Path.join(System.tmp_dir!(), "hgs_surrealdb_sdk_#{suffix}")
    File.mkdir_p!(path)

    contents = """
    -- migrate:up
    DEFINE TABLE #{table} SCHEMALESS;

    -- migrate:down
    REMOVE TABLE #{table};
    """

    File.write!(Path.join(path, filename), contents)

    on_exit(fn ->
      File.rm_rf(path)

      assert {:ok, %QueryResult{}} =
               SurrealDB.query(client, "DELETE schema_migrations WHERE filename = $filename;", %{
                 filename: filename
               })

      assert {:ok, %QueryResult{}} = SurrealDB.query(client, "REMOVE TABLE IF EXISTS #{table};")
    end)

    assert :ok = Migrations.install_registry(client)

    assert {:ok, [%{filename: ^filename, status: :applied}]} =
             Migrations.run(client, path: path, sdk_version: "0.1.0")

    assert {:ok, [%{filename: ^filename, status: :skipped}]} =
             Migrations.run(client, path: path, sdk_version: "0.1.0")

    File.write!(Path.join(path, filename), contents <> "\n-- checksum drift\n")

    assert {:error, %Error{type: :migration_checksum_drift}} =
             Migrations.run(client, path: path, sdk_version: "0.1.0")

    File.write!(Path.join(path, filename), contents)

    assert {:ok, [%{filename: ^filename, reverted?: true}]} =
             Migrations.rollback(client, path: path, steps: 1)
  end
end
