defmodule SurrealDB.Migration.Registry do
  @moduledoc """
  Encapsulates reads/writes against the SDK migration registry table.

  CODEX_TODO: Adapt `query/3` and `use_db/3` to the actual SDK client API.
  """

  alias SurrealDB.Migration
  alias SurrealDB.Migration.Checksum

  @registry_schema_path "priv/surrealdb_migrations/sdk_registry/001_define_migration_registry.surql"

  @default_registry_ns "sdk_meta"
  @default_registry_db "migration_registry"

  def default_registry_ns, do: @default_registry_ns
  def default_registry_db, do: @default_registry_db

  @doc """
  Installs the registry schema into the registry namespace/database.
  """
  def install(client, opts \\ []) do
    registry_ns = Keyword.get(opts, :registry_ns, @default_registry_ns)
    registry_db = Keyword.get(opts, :registry_db, @default_registry_db)
    schema_path = Keyword.get(opts, :schema_path, @registry_schema_path)

    with {:ok, contents} <- File.read(schema_path),
         {:ok, registry_client} <- use_db(client, registry_ns, registry_db),
         {:ok, _result} <- query(registry_client, contents, %{}) do
      :ok
    end
  end

  @doc """
  Finds an existing registry row by target namespace/database and filename.
  """
  def find_by_filename(client, target_ns, target_db, filename, opts \\ []) do
    with {:ok, registry_client} <- registry_client(client, opts) do
      query(registry_client, """
      SELECT id, migration_key, target_ns, target_db, filename, checksum, sdk_version,
             status, applied_at, started_at, finished_at, duration_ms, error_message, attempt_count
      FROM sdk_migration
      WHERE target_ns = $target_ns
        AND target_db = $target_db
        AND filename = $filename
      LIMIT 1;
      """, %{
        "target_ns" => target_ns,
        "target_db" => target_db,
        "filename" => filename
      })
    end
  end

  @doc """
  Inserts a `running` row before the actual migration is executed.
  """
  def mark_running(client, target_ns, target_db, %Migration{} = migration, sdk_version, opts \\ []) do
    migration_key = Checksum.migration_key(target_ns, target_db, migration.filename)

    with {:ok, registry_client} <- registry_client(client, opts) do
      query(registry_client, """
      INSERT INTO sdk_migration CONTENT {
        migration_key: $migration_key,
        target_ns: $target_ns,
        target_db: $target_db,
        filename: $filename,
        checksum: $checksum,
        sdk_version: $sdk_version,
        status: 'running',
        started_at: time::now(),
        finished_at: NONE,
        applied_at: NONE,
        duration_ms: NONE,
        error_message: NONE,
        attempt_count: 1,
        created_at: time::now(),
        updated_at: time::now()
      };
      """, %{
        "migration_key" => migration_key,
        "target_ns" => target_ns,
        "target_db" => target_db,
        "filename" => migration.filename,
        "checksum" => migration.checksum,
        "sdk_version" => sdk_version
      })
    end
  end

  @doc """
  Marks a running migration as applied.
  """
  def mark_applied(client, target_ns, target_db, %Migration{} = migration, duration_ms, opts \\ []) do
    with {:ok, registry_client} <- registry_client(client, opts) do
      query(registry_client, """
      UPDATE sdk_migration
      SET
        status = 'applied',
        applied_at = time::now(),
        finished_at = time::now(),
        duration_ms = $duration_ms,
        error_message = NONE,
        updated_at = time::now()
      WHERE target_ns = $target_ns
        AND target_db = $target_db
        AND filename = $filename
        AND checksum = $checksum
        AND status = 'running';
      """, %{
        "target_ns" => target_ns,
        "target_db" => target_db,
        "filename" => migration.filename,
        "checksum" => migration.checksum,
        "duration_ms" => duration_ms
      })
    end
  end

  @doc """
  Marks a running migration as failed.
  """
  def mark_failed(client, target_ns, target_db, %Migration{} = migration, duration_ms, error_message, opts \\ []) do
    with {:ok, registry_client} <- registry_client(client, opts) do
      query(registry_client, """
      UPDATE sdk_migration
      SET
        status = 'failed',
        finished_at = time::now(),
        duration_ms = $duration_ms,
        error_message = $error_message,
        updated_at = time::now()
      WHERE target_ns = $target_ns
        AND target_db = $target_db
        AND filename = $filename
        AND checksum = $checksum
        AND status = 'running';
      """, %{
        "target_ns" => target_ns,
        "target_db" => target_db,
        "filename" => migration.filename,
        "checksum" => migration.checksum,
        "duration_ms" => duration_ms,
        "error_message" => error_message
      })
    end
  end

  defp registry_client(client, opts) do
    registry_ns = Keyword.get(opts, :registry_ns, @default_registry_ns)
    registry_db = Keyword.get(opts, :registry_db, @default_registry_db)
    use_db(client, registry_ns, registry_db)
  end

  defp use_db(client, ns, db) do
    # CODEX_TODO: Replace this shim with the SDK's real namespace/database selection API.
    # Expected return shape: {:ok, client_for_ns_db}
    if function_exported?(SurrealDB, :use, 3) do
      {:ok, apply(SurrealDB, :use, [client, ns, db])}
    else
      {:ok, %{client: client, ns: ns, db: db}}
    end
  end

  defp query(client, surql, params) do
    # CODEX_TODO: Replace this shim with the SDK's real query API.
    cond do
      function_exported?(SurrealDB, :query, 3) ->
        SurrealDB.query(client, surql, params)

      function_exported?(SurrealDB, :query!, 3) ->
        {:ok, SurrealDB.query!(client, surql, params)}

      true ->
        {:error, {:sdk_query_api_not_wired, client, surql, params}}
    end
  end
end
