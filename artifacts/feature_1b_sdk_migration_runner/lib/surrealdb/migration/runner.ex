defmodule SurrealDB.Migration.Runner do
  @moduledoc """
  Coordinates discovery, preflight, execution, and registry updates for `.surql` migrations.

  CODEX_TODO: Wire `execute_migration/5` to the actual SDK query API.
  """

  alias SurrealDB.Migration
  alias SurrealDB.Migration.FileLoader
  alias SurrealDB.Migration.Registry

  @type migration_result ::
          {:applied, String.t()}
          | {:skipped, String.t()}

  def install_registry(client, opts \\ []) do
    Registry.install(client, opts)
  end

  @doc """
  Runs all `.surql` files in `opts[:path]` against `opts[:target_ns]` / `opts[:target_db]`.
  """
  def run(client, opts) do
    with {:ok, config} <- validate_opts(opts),
         migrations <- FileLoader.load!(config.path) do
      run_migrations(client, migrations, config)
    rescue
      error -> {:error, error}
    end
  end

  defp validate_opts(opts) do
    required = [:path, :target_ns, :target_db, :sdk_version]

    missing = Enum.filter(required, &(not Keyword.has_key?(opts, &1)))

    if missing == [] do
      {:ok,
       %{
         path: Keyword.fetch!(opts, :path),
         target_ns: Keyword.fetch!(opts, :target_ns),
         target_db: Keyword.fetch!(opts, :target_db),
         sdk_version: Keyword.fetch!(opts, :sdk_version),
         registry_ns: Keyword.get(opts, :registry_ns, Registry.default_registry_ns()),
         registry_db: Keyword.get(opts, :registry_db, Registry.default_registry_db()),
         allow_failed_rerun?: Keyword.get(opts, :allow_failed_rerun?, false)
       }}
    else
      {:error, {:missing_required_options, missing}}
    end
  end

  defp run_migrations(client, migrations, config) do
    Enum.reduce_while(migrations, {:ok, []}, fn migration, {:ok, acc} ->
      case run_one(client, migration, config) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  defp run_one(client, %Migration{} = migration, config) do
    registry_opts = [registry_ns: config.registry_ns, registry_db: config.registry_db]

    with :ok <- preflight(client, migration, config, registry_opts),
         {:ok, _} <- Registry.mark_running(client, config.target_ns, config.target_db, migration, config.sdk_version, registry_opts) do
      {duration_ms, result} = timed(fn -> execute_migration(client, migration, config) end)

      case result do
        :ok ->
          with {:ok, _} <- Registry.mark_applied(client, config.target_ns, config.target_db, migration, duration_ms, registry_opts) do
            {:ok, {:applied, migration.filename}}
          end

        {:error, reason} ->
          _ = Registry.mark_failed(client, config.target_ns, config.target_db, migration, duration_ms, inspect(reason), registry_opts)
          {:error, {:migration_failed, migration.filename, reason}}
      end
    else
      {:skip, :already_applied} -> {:ok, {:skipped, migration.filename}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp preflight(client, %Migration{} = migration, config, registry_opts) do
    case Registry.find_by_filename(client, config.target_ns, config.target_db, migration.filename, registry_opts) do
      {:ok, []} ->
        :ok

      {:ok, [%{"status" => "applied", "checksum" => checksum}]} when checksum == migration.checksum ->
        {:skip, :already_applied}

      {:ok, [%{"status" => "applied", "checksum" => stored_checksum}]} ->
        {:error, {:checksum_drift, migration.filename, stored_checksum, migration.checksum}}

      {:ok, [%{"status" => "running"}]} ->
        {:error, {:migration_already_running, migration.filename}}

      {:ok, [%{"status" => "failed"}]} ->
        if config.allow_failed_rerun? do
          :ok
        else
          {:error, {:previous_migration_failed, migration.filename}}
        end

      {:ok, [other]} ->
        {:error, {:unknown_registry_state, migration.filename, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_migration(client, %Migration{} = migration, config) do
    # CODEX_TODO: Replace this shim with the SDK's real namespace/database selection and query API.
    cond do
      function_exported?(SurrealDB, :use, 3) and function_exported?(SurrealDB, :query, 3) ->
        client
        |> apply_use(config.target_ns, config.target_db)
        |> SurrealDB.query(migration.contents, %{})
        |> normalize_query_result()

      function_exported?(SurrealDB, :use, 3) and function_exported?(SurrealDB, :query!, 3) ->
        client
        |> apply_use(config.target_ns, config.target_db)
        |> SurrealDB.query!(migration.contents, %{})

        :ok

      true ->
        {:error, :sdk_query_api_not_wired}
    end
  end

  defp apply_use(client, ns, db), do: apply(SurrealDB, :use, [client, ns, db])

  defp normalize_query_result({:ok, _result}), do: :ok
  defp normalize_query_result(:ok), do: :ok
  defp normalize_query_result({:error, reason}), do: {:error, reason}
  defp normalize_query_result(other), do: {:error, {:unexpected_query_result, other}}

  defp timed(fun) when is_function(fun, 0) do
    start = System.monotonic_time(:millisecond)
    result = fun.()
    finish = System.monotonic_time(:millisecond)
    {max(finish - start, 0), result}
  end
end
