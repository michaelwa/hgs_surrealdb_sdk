defmodule SurrealDB.Migrations do
  @moduledoc """
  Runs SurrealDB `.surql` migrations with an SDK-managed registry.
  """

  alias SurrealDB.Client
  alias SurrealDB.Error
  alias SurrealDB.QueryResult

  @default_registry_ns "sdk_meta"
  @default_registry_db "migration_registry"
  @registry_schema_path "surrealdb_migrations/sdk_registry/001_define_migration_registry.surql"

  @type run_result :: %{
          filename: String.t(),
          checksum: String.t(),
          status: :applied | :skipped
        }

  @type registry_row :: map()

  @spec install_registry(Client.t(), keyword()) :: :ok | {:error, Error.t()}
  def install_registry(%Client{} = client, opts \\ []) when is_list(opts) do
    with :ok <- ensure_http_client(client),
         {:ok, schema} <- load_registry_schema(),
         {:ok, _result} <- SurrealDB.query(registry_client(client, opts), schema) do
      :ok
    end
  end

  @spec install_registry!(Client.t(), keyword()) :: :ok
  def install_registry!(%Client{} = client, opts \\ []) when is_list(opts) do
    case install_registry(client, opts) do
      :ok -> :ok
      {:error, %Error{} = error} -> raise error
    end
  end

  @spec run(Client.t(), keyword()) :: {:ok, [run_result()]} | {:error, Error.t()}
  def run(%Client{} = client, opts) when is_list(opts) do
    with :ok <- ensure_http_client(client),
         {:ok, config} <- build_run_config(opts),
         {:ok, migrations} <- load_migrations(config.path),
         :ok <- install_registry(client, opts) do
      registry = registry_client(client, opts)
      target = target_client(client, config)

      run_migrations(migrations, registry, target, config, [])
    end
  end

  @spec run!(Client.t(), keyword()) :: [run_result()]
  def run!(%Client{} = client, opts) when is_list(opts) do
    case run(client, opts) do
      {:ok, results} -> results
      {:error, %Error{} = error} -> raise error
    end
  end

  @spec status(Client.t(), keyword()) :: {:ok, [registry_row()]} | {:error, Error.t()}
  def status(%Client{} = client, opts) when is_list(opts) do
    with :ok <- ensure_http_client(client),
         {:ok, config} <- build_target_config(opts) do
      query = """
      SELECT migration_key, target_ns, target_db, filename, checksum, sdk_version, status, applied_at, started_at, finished_at, duration_ms, error_message, attempt_count
      FROM sdk_migration
      WHERE target_ns = $target_ns
        AND target_db = $target_db
      ORDER BY filename ASC;
      """

      with {:ok, %QueryResult{} = result} <-
             SurrealDB.query(registry_client(client, opts), query, target_variables(config)),
           {:ok, rows} <- first_statement_rows(result) do
        {:ok, rows}
      end
    end
  end

  @spec status!(Client.t(), keyword()) :: [registry_row()]
  def status!(%Client{} = client, opts) when is_list(opts) do
    case status(client, opts) do
      {:ok, rows} -> rows
      {:error, %Error{} = error} -> raise error
    end
  end

  @spec reset(Client.t(), keyword()) :: {:ok, QueryResult.t()} | {:error, Error.t()}
  def reset(%Client{} = client, opts) when is_list(opts) do
    with :ok <- ensure_http_client(client),
         {:ok, config} <- build_target_config(opts) do
      query = """
      DELETE sdk_migration
      WHERE target_ns = $target_ns
        AND target_db = $target_db;
      """

      SurrealDB.query(registry_client(client, opts), query, target_variables(config))
    end
  end

  @spec reset!(Client.t(), keyword()) :: QueryResult.t()
  def reset!(%Client{} = client, opts) when is_list(opts) do
    case reset(client, opts) do
      {:ok, result} -> result
      {:error, %Error{} = error} -> raise error
    end
  end

  @spec rollback(Client.t(), keyword()) :: {:ok, [registry_row()]} | {:error, Error.t()}
  def rollback(%Client{} = client, opts) when is_list(opts) do
    with :ok <- ensure_http_client(client),
         {:ok, config} <- build_rollback_config(opts),
         {:ok, rows} <- applied_rows_for_rollback(registry_client(client, opts), config),
         :ok <- execute_down_files(client, config, rows),
         {:ok, _result} <- delete_rolled_back_rows(registry_client(client, opts), config, rows) do
      {:ok, rows}
    end
  end

  @spec rollback!(Client.t(), keyword()) :: [registry_row()]
  def rollback!(%Client{} = client, opts) when is_list(opts) do
    case rollback(client, opts) do
      {:ok, rows} -> rows
      {:error, %Error{} = error} -> raise error
    end
  end

  defp build_run_config(opts) do
    missing =
      [:path, :target_ns, :target_db, :sdk_version]
      |> Enum.filter(&blank?(Keyword.get(opts, &1)))

    case missing do
      [] ->
        {:ok,
         %{
           path: Keyword.fetch!(opts, :path),
           target_ns: Keyword.fetch!(opts, :target_ns),
           target_db: Keyword.fetch!(opts, :target_db),
           sdk_version: Keyword.fetch!(opts, :sdk_version),
           allow_failed_rerun?: Keyword.get(opts, :allow_failed_rerun?, false),
           step: Keyword.get(opts, :step),
           to: Keyword.get(opts, :to),
           to_exclusive: Keyword.get(opts, :to_exclusive)
         }}

      _ ->
        {:error,
         migration_error("missing required migration options",
           type: :invalid_migration_options,
           details: %{missing: missing}
         )}
    end
  end

  defp build_target_config(opts) do
    missing =
      [:target_ns, :target_db]
      |> Enum.filter(&blank?(Keyword.get(opts, &1)))

    case missing do
      [] ->
        {:ok,
         %{
           target_ns: Keyword.fetch!(opts, :target_ns),
           target_db: Keyword.fetch!(opts, :target_db)
         }}

      _ ->
        {:error,
         migration_error("missing required migration options",
           type: :invalid_migration_options,
           details: %{missing: missing}
         )}
    end
  end

  defp build_rollback_config(opts) do
    with {:ok, config} <- build_target_config(opts),
         {:ok, steps} <- validate_rollback_steps(Keyword.get(opts, :steps, 1)) do
      {:ok,
       Map.merge(config, %{
         steps: steps,
         down_path: Keyword.get(opts, :down_path),
         to: Keyword.get(opts, :to),
         to_exclusive: Keyword.get(opts, :to_exclusive)
       })}
    end
  end

  defp validate_rollback_steps(steps) when is_integer(steps) and steps > 0, do: {:ok, steps}

  defp validate_rollback_steps(steps) do
    {:error,
     migration_error("rollback steps must be a positive integer",
       type: :invalid_migration_options,
       details: %{steps: steps}
     )}
  end

  defp applied_rows_for_rollback(registry, config) do
    query = """
    SELECT migration_key, target_ns, target_db, filename, checksum, sdk_version, status, applied_at, attempt_count
    FROM sdk_migration
    WHERE target_ns = $target_ns
      AND target_db = $target_db
      AND status = 'applied'
      #{rollback_version_filter(config)}
    ORDER BY filename DESC
    LIMIT #{config.steps};
    """

    with {:ok, %QueryResult{} = result} <-
           SurrealDB.query(registry, query, target_variables(config)),
         {:ok, rows} <- first_statement_rows(result) do
      {:ok, rows}
    end
  end

  defp execute_down_files(_client, %{down_path: nil}, _rows), do: :ok
  defp execute_down_files(_client, %{down_path: ""}, _rows), do: :ok

  defp execute_down_files(client, config, rows) do
    target = target_client(client, config)

    Enum.reduce_while(rows, :ok, fn row, :ok ->
      path = Path.join(config.down_path, Map.fetch!(row, "filename"))

      with {:ok, contents} <- read_down_file(path),
           {:ok, _result} <- SurrealDB.query(target, contents) do
        {:cont, :ok}
      else
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp read_down_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        {:ok, contents}

      {:error, reason} ->
        {:error,
         migration_error("failed to read rollback migration file",
           type: :migration_file_error,
           details: %{path: path, reason: reason}
         )}
    end
  end

  defp delete_rolled_back_rows(_registry, _config, []), do: {:ok, %QueryResult{results: []}}

  defp delete_rolled_back_rows(registry, config, rows) do
    filenames = Enum.map(rows, &Map.fetch!(&1, "filename"))

    query = """
    DELETE sdk_migration
    WHERE target_ns = $target_ns
      AND target_db = $target_db
      AND filename IN $filenames
      AND status = 'applied';
    """

    variables =
      config
      |> target_variables()
      |> Map.put(:filenames, filenames)

    SurrealDB.query(registry, query, variables)
  end

  defp rollback_version_filter(%{to: to}) when is_binary(to) and to != "" do
    "AND filename >= #{Jason.encode!(to)}"
  end

  defp rollback_version_filter(%{to_exclusive: to_exclusive})
       when is_binary(to_exclusive) and to_exclusive != "" do
    "AND filename > #{Jason.encode!(to_exclusive)}"
  end

  defp rollback_version_filter(_config), do: ""

  defp load_migrations(paths) when is_list(paths) do
    paths
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, acc} ->
      case load_migrations(path) do
        {:ok, migrations} -> {:cont, {:ok, acc ++ migrations}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, migrations} -> {:ok, Enum.sort_by(migrations, & &1.filename)}
      other -> other
    end
  end

  defp load_migrations(path) when is_binary(path) do
    if File.dir?(path) do
      case File.ls(path) do
        {:ok, filenames} ->
          filenames
          |> Enum.filter(&String.ends_with?(&1, ".surql"))
          |> Enum.sort()
          |> Enum.reduce_while({:ok, []}, fn filename, {:ok, acc} ->
            full_path = Path.join(path, filename)

            case File.read(full_path) do
              {:ok, contents} ->
                migration = %{
                  filename: filename,
                  path: full_path,
                  contents: contents,
                  checksum: checksum(contents)
                }

                {:cont, {:ok, [migration | acc]}}

              {:error, reason} ->
                {:halt,
                 {:error,
                  migration_error("failed to read migration file",
                    type: :migration_file_error,
                    details: %{path: full_path, reason: reason}
                  )}}
            end
          end)
          |> case do
            {:ok, migrations} -> {:ok, Enum.reverse(migrations)}
            other -> other
          end

        {:error, reason} ->
          {:error,
           migration_error("failed to list migration path",
             type: :migration_file_error,
             details: %{path: path, reason: reason}
           )}
      end
    else
      {:error,
       migration_error("migration path does not exist",
         type: :migration_path_not_found,
         details: %{path: path}
       )}
    end
  end

  defp load_migrations(path) do
    {:error,
     migration_error("migration path must be a string",
       type: :invalid_migration_options,
       details: %{path: path}
     )}
  end

  defp checksum(contents) when is_binary(contents) do
    hash = :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
    "sha256:" <> hash
  end

  defp run_migrations(migrations, registry, target, config, acc) do
    migrations
    |> filter_migrations(config)
    |> do_run_migrations(registry, target, config, acc)
  end

  defp filter_migrations(migrations, config) do
    migrations
    |> filter_to(config)
    |> filter_to_exclusive(config)
    |> filter_step(config)
  end

  defp filter_to(migrations, %{to: to}) when is_binary(to) and to != "" do
    Enum.filter(migrations, &(migration_version(&1.filename) <= to))
  end

  defp filter_to(migrations, _config), do: migrations

  defp filter_to_exclusive(migrations, %{to_exclusive: to_exclusive})
       when is_binary(to_exclusive) and to_exclusive != "" do
    Enum.filter(migrations, &(migration_version(&1.filename) < to_exclusive))
  end

  defp filter_to_exclusive(migrations, _config), do: migrations

  defp filter_step(migrations, %{step: step}) when is_integer(step) and step > 0 do
    Enum.take(migrations, step)
  end

  defp filter_step(migrations, _config), do: migrations

  defp migration_version(filename) do
    case Regex.run(~r/\A(\d+)/, filename) do
      [_, version] -> version
      _ -> filename
    end
  end

  defp do_run_migrations([], _registry, _target, _config, acc), do: {:ok, Enum.reverse(acc)}

  defp do_run_migrations([migration | rest], registry, target, config, acc) do
    with {:ok, decision} <- preflight(registry, migration, config),
         {:ok, result} <- execute_decision(decision, registry, target, migration, config) do
      do_run_migrations(rest, registry, target, config, [result | acc])
    end
  end

  defp preflight(registry, migration, config) do
    with {:ok, row} <- lookup_registry_row(registry, migration, config) do
      preflight_row(row, migration, config)
    end
  end

  defp lookup_registry_row(registry, migration, config) do
    query = """
    SELECT id, migration_key, target_ns, target_db, filename, checksum, status, applied_at, error_message, attempt_count
    FROM sdk_migration
    WHERE target_ns = $target_ns
      AND target_db = $target_db
      AND filename = $filename
    LIMIT 1;
    """

    variables = registry_variables(migration, config)

    with {:ok, %QueryResult{} = result} <- SurrealDB.query(registry, query, variables),
         {:ok, rows} <- first_statement_rows(result) do
      {:ok, List.first(rows)}
    end
  end

  defp preflight_row(nil, _migration, _config), do: {:ok, :new}

  defp preflight_row(
         %{"status" => "applied", "checksum" => checksum},
         %{checksum: checksum},
         _config
       ) do
    {:ok, :skip}
  end

  defp preflight_row(%{"status" => "applied"} = row, migration, _config) do
    {:error,
     migration_error("migration checksum drift detected",
       type: :migration_checksum_drift,
       details: %{
         filename: migration.filename,
         stored_checksum: row["checksum"],
         current_checksum: migration.checksum
       },
       raw: row
     )}
  end

  defp preflight_row(%{"status" => "running"} = row, migration, _config) do
    {:error,
     migration_error("migration is already running",
       type: :migration_already_running,
       details: %{filename: migration.filename},
       raw: row
     )}
  end

  defp preflight_row(%{"status" => "failed"} = row, _migration, %{allow_failed_rerun?: true}) do
    {:ok, {:rerun_failed, row}}
  end

  defp preflight_row(%{"status" => "failed"} = row, migration, _config) do
    {:error,
     migration_error("migration previously failed",
       type: :migration_failed_rerun_not_allowed,
       details: %{filename: migration.filename, error_message: row["error_message"]},
       raw: row
     )}
  end

  defp preflight_row(row, migration, _config) do
    {:error,
     migration_error("migration registry row has unsupported status",
       type: :migration_invalid_registry_state,
       details: %{filename: migration.filename, status: row["status"]},
       raw: row
     )}
  end

  defp execute_decision(:skip, _registry, _target, migration, _config) do
    {:ok, %{filename: migration.filename, checksum: migration.checksum, status: :skipped}}
  end

  defp execute_decision(:new, registry, target, migration, config) do
    execute_migration(:new, registry, target, migration, config)
  end

  defp execute_decision({:rerun_failed, _row} = decision, registry, target, migration, config) do
    execute_migration(decision, registry, target, migration, config)
  end

  defp execute_migration(decision, registry, target, migration, config) do
    with {:ok, _} <- mark_running(registry, migration, config, decision) do
      started = System.monotonic_time(:millisecond)

      case SurrealDB.query(target, migration.contents) do
        {:ok, migration_result} ->
          duration_ms = System.monotonic_time(:millisecond) - started

          with {:ok, _} <- mark_applied(registry, migration, config, duration_ms) do
            {:ok,
             %{
               filename: migration.filename,
               checksum: migration.checksum,
               status: :applied,
               result: migration_result
             }}
          end

        {:error, %Error{} = error} ->
          duration_ms = System.monotonic_time(:millisecond) - started
          _ = mark_failed(registry, migration, config, duration_ms, error)

          {:error,
           migration_error("migration execution failed",
             type: :migration_execution_failed,
             details: %{filename: migration.filename, error: error.message},
             raw: error
           )}
      end
    end
  end

  defp mark_running(registry, migration, config, :new) do
    query = """
    INSERT INTO sdk_migration {
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
    """

    SurrealDB.query(registry, query, registry_variables(migration, config))
  end

  defp mark_running(registry, migration, config, {:rerun_failed, _row}) do
    query = """
    UPDATE sdk_migration
    SET
      status = 'running',
      started_at = time::now(),
      finished_at = NONE,
      applied_at = NONE,
      duration_ms = NONE,
      error_message = NONE,
      sdk_version = $sdk_version,
      checksum = $checksum,
      attempt_count += 1,
      updated_at = time::now()
    WHERE target_ns = $target_ns
      AND target_db = $target_db
      AND filename = $filename
      AND status = 'failed';
    """

    SurrealDB.query(registry, query, registry_variables(migration, config))
  end

  defp mark_applied(registry, migration, config, duration_ms) do
    query = """
    UPDATE sdk_migration
    SET
      status = 'applied',
      applied_at = time::now(),
      finished_at = time::now(),
      duration_ms = $duration_ms,
      error_message = NONE,
      sdk_version = $sdk_version,
      updated_at = time::now()
    WHERE target_ns = $target_ns
      AND target_db = $target_db
      AND filename = $filename
      AND checksum = $checksum
      AND status = 'running';
    """

    variables =
      migration
      |> registry_variables(config)
      |> Map.put(:duration_ms, duration_ms)

    SurrealDB.query(registry, query, variables)
  end

  defp mark_failed(registry, migration, config, duration_ms, %Error{} = error) do
    query = """
    UPDATE sdk_migration
    SET
      status = 'failed',
      finished_at = time::now(),
      duration_ms = $duration_ms,
      error_message = $error_message,
      sdk_version = $sdk_version,
      updated_at = time::now()
    WHERE target_ns = $target_ns
      AND target_db = $target_db
      AND filename = $filename
      AND checksum = $checksum
      AND status = 'running';
    """

    variables =
      migration
      |> registry_variables(config)
      |> Map.merge(%{duration_ms: duration_ms, error_message: error.message})

    SurrealDB.query(registry, query, variables)
  end

  defp first_statement_rows(%QueryResult{results: [rows | _]}) when is_list(rows), do: {:ok, rows}
  defp first_statement_rows(%QueryResult{results: [nil | _]}), do: {:ok, []}
  defp first_statement_rows(%QueryResult{results: []}), do: {:ok, []}

  defp first_statement_rows(%QueryResult{} = result) do
    {:error,
     migration_error("unexpected registry query result",
       type: :migration_registry_result_error,
       details: %{results: inspect(result.results)},
       raw: result
     )}
  end

  defp load_registry_schema do
    case registry_schema_file() do
      {:ok, path} ->
        case File.read(path) do
          {:ok, schema} ->
            {:ok, schema}

          {:error, reason} ->
            {:error,
             migration_error("failed to read registry schema",
               type: :migration_registry_schema_error,
               details: %{path: path, reason: reason}
             )}
        end

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp registry_schema_file do
    priv_path =
      :hgs_surrealdb_sdk
      |> :code.priv_dir()
      |> case do
        path when is_list(path) -> Path.join(List.to_string(path), @registry_schema_path)
        {:error, _reason} -> nil
      end

    local_path = Path.join(["priv", @registry_schema_path])

    cond do
      is_binary(priv_path) and File.exists?(priv_path) ->
        {:ok, priv_path}

      File.exists?(local_path) ->
        {:ok, local_path}

      true ->
        {:error,
         migration_error("registry schema file was not found",
           type: :migration_registry_schema_error,
           details: %{priv_path: priv_path, local_path: local_path}
         )}
    end
  end

  defp registry_client(%Client{} = client, opts) do
    %Client{
      client
      | namespace: Keyword.get(opts, :registry_ns, @default_registry_ns),
        database: Keyword.get(opts, :registry_db, @default_registry_db)
    }
  end

  defp target_client(%Client{} = client, config) do
    %Client{client | namespace: config.target_ns, database: config.target_db}
  end

  defp target_variables(config) do
    %{
      target_ns: config.target_ns,
      target_db: config.target_db
    }
  end

  defp registry_variables(migration, config) do
    %{
      migration_key: migration_key(config.target_ns, config.target_db, migration.filename),
      target_ns: config.target_ns,
      target_db: config.target_db,
      filename: migration.filename,
      checksum: migration.checksum,
      sdk_version: config.sdk_version
    }
  end

  defp migration_key(target_ns, target_db, filename) do
    key = Enum.join([target_ns, target_db, filename], "\0")
    hash = :crypto.hash(:sha256, key) |> Base.encode16(case: :lower)
    "sdk_migration:" <> hash
  end

  defp ensure_http_client(%Client{transport: :http}), do: :ok

  defp ensure_http_client(%Client{transport: :websocket}) do
    {:error,
     migration_error("migrations support HTTP clients only",
       type: :unsupported_client_for_migrations,
       details: %{transport: :websocket}
     )}
  end

  defp ensure_http_client(%Client{transport: transport}) do
    {:error,
     migration_error("migrations support HTTP clients only",
       type: :unsupported_client_for_migrations,
       details: %{transport: transport}
     )}
  end

  defp migration_error(message, opts) do
    %Error{
      type: Keyword.fetch!(opts, :type),
      message: message,
      details: Keyword.get(opts, :details, %{}),
      raw: Keyword.get(opts, :raw)
    }
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(value), do: is_nil(value)
end
