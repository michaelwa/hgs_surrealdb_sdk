defmodule Mix.Tasks.Surreal.MigrationTaskHelpers do
  @moduledoc false

  alias SurrealDB.Client
  alias SurrealDB.Config
  alias SurrealDB.Error

  @default_repo_path "priv/surreal_repo"

  @switches [
    store: :string,
    endpoint: :string,
    namespace: :string,
    database: :string,
    username: :string,
    password: :string,
    auth_token: :string,
    anonymous: :boolean,
    migrations_path: :keep,
    path: :string,
    repo_path: :string,
    sdk_version: :string,
    allow_failed_rerun: :boolean,
    step: :integer,
    steps: :integer,
    to: :string,
    to_exclusive: :string,
    all: :boolean,
    force: :boolean,
    migrate: :boolean,
    output: :string,
    input: :string,
    no_compile: :boolean,
    no_deps_check: :boolean,
    quiet: :boolean,
    repo: :keep
  ]

  @aliases [
    e: :endpoint,
    n: :step,
    d: :database,
    u: :username,
    p: :password,
    r: :store
  ]

  def parse!(argv) do
    case OptionParser.parse(argv, switches: @switches, aliases: @aliases) do
      {opts, [], []} -> opts
      {_opts, args, []} -> Mix.raise("unexpected arguments: #{Enum.join(args, " ")}")
      {_opts, _args, invalid} -> Mix.raise("invalid options: #{inspect(invalid)}")
    end
  end

  def parse_with_args!(argv) do
    case OptionParser.parse(argv, switches: @switches, aliases: @aliases) do
      {opts, args, []} -> {opts, args}
      {_opts, _args, invalid} -> Mix.raise("invalid options: #{inspect(invalid)}")
    end
  end

  def build_client!(opts) do
    opts
    |> client_options()
    |> Config.build_client()
    |> unwrap!()
  end

  def migration_opts(%Client{} = _client, opts) do
    [
      path: migration_paths(opts),
      sdk_version: Keyword.get(opts, :sdk_version, project_version())
    ]
    |> maybe_put(:allow_failed_rerun?, Keyword.get(opts, :allow_failed_rerun))
    |> maybe_put(:step, Keyword.get(opts, :step))
    |> maybe_put(:to, Keyword.get(opts, :to))
    |> maybe_put(:to_exclusive, Keyword.get(opts, :to_exclusive))
  end

  def target_opts(%Client{} = _client, opts) do
    [path: migration_paths(opts)]
    |> maybe_put(:steps, rollback_steps(opts))
    |> maybe_put(:to, Keyword.get(opts, :to))
    |> maybe_put(:to_exclusive, Keyword.get(opts, :to_exclusive))
  end

  def repo_path(opts) do
    cond do
      present?(Keyword.get(opts, :repo_path)) -> Keyword.get(opts, :repo_path)
      present?(repo_path_from_store(opts)) -> repo_path_from_store(opts)
      true -> @default_repo_path
    end
  end

  def migration_paths(opts) do
    explicit =
      Keyword.get_values(opts, :migrations_path) ++
        Keyword.get_values(opts, :path)

    case explicit do
      [] -> Path.join(repo_path(opts), "migrations")
      [path] -> path
      paths -> paths
    end
  end

  def migration_path(opts) do
    case migration_paths(opts) do
      [path | _] -> path
      path -> path
    end
  end

  def rollback_steps(opts) do
    cond do
      Keyword.get(opts, :all, false) -> 9_223_372_036_854_775_807
      is_integer(Keyword.get(opts, :step)) -> Keyword.get(opts, :step)
      is_integer(Keyword.get(opts, :steps)) -> Keyword.get(opts, :steps)
      true -> nil
    end
  end

  def target_scope(%Client{} = client, opts) do
    {
      Keyword.get(opts, :namespace, client.namespace),
      Keyword.get(opts, :database, client.database)
    }
  end

  def create_database!(%Client{} = client, opts) do
    {namespace, database} = target_scope(client, opts)
    namespace = quote_identifier!(namespace, "namespace")
    database = quote_identifier!(database, "database")

    query = """
    DEFINE NAMESPACE IF NOT EXISTS #{namespace};
    USE NS #{namespace};
    DEFINE DATABASE IF NOT EXISTS #{database};
    """

    client
    |> SurrealDB.query(query)
    |> unwrap!()

    {namespace, database}
  end

  def drop_database!(%Client{} = client, opts) do
    {namespace, database} = target_scope(client, opts)
    namespace = quote_identifier!(namespace, "namespace")
    database = quote_identifier!(database, "database")

    existed? = database_exists?(client, namespace, database)

    query = """
    USE NS #{namespace};
    REMOVE DATABASE IF EXISTS #{database};
    """

    client
    |> SurrealDB.query(query)
    |> unwrap!()

    {namespace, database, existed?}
  end

  defp database_exists?(%Client{} = client, namespace, database) do
    result =
      client
      |> SurrealDB.query("USE NS #{namespace};\nINFO FOR NS;")
      |> unwrap!()

    databases =
      case List.last(result.results) do
        %{"databases" => dbs} when is_map(dbs) -> dbs
        _ -> %{}
      end

    Map.has_key?(databases, database)
  end

  def quote_identifier!(value, kind) when is_binary(value) do
    trimmed = String.trim(value)

    if Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, trimmed) do
      trimmed
    else
      Mix.raise("#{kind} must be a simple SurrealDB identifier, got: #{inspect(value)}")
    end
  end

  def quote_identifier!(value, kind) do
    Mix.raise("#{kind} must be a string, got: #{inspect(value)}")
  end

  def unwrap!({:ok, value}), do: value

  def unwrap!({:error, %Error{} = error}) do
    Mix.raise("#{error.message} (#{error.type}): #{inspect(error.details)}")
  end

  def print_run_results(results) do
    applied = Enum.count(results, &(&1.status == :applied))
    skipped = Enum.count(results, &(&1.status == :skipped))

    Mix.shell().info("Migrations complete: #{applied} applied, #{skipped} skipped.")

    Enum.each(results, fn result ->
      Mix.shell().info("  #{result.status} #{result.filename}")
    end)
  end

  def print_rows([]), do: Mix.shell().info("No migrations recorded.")

  def print_rows(rows) do
    Enum.each(rows, fn row ->
      Mix.shell().info(
        "#{Map.get(row, "status", "unknown")} #{Map.get(row, "filename", "(unknown)")} #{Map.get(row, "applied_at", "")}"
      )
    end)
  end

  defp client_options(opts) do
    opts
    |> store_options()
    |> Keyword.merge(cli_connection_overrides(opts))
    |> put_default(:endpoint, "http://localhost:8000")
    |> ensure_scope!()
    |> put_default_auth()
  end

  defp ensure_scope!(opts) do
    if present?(Keyword.get(opts, :namespace)) and present?(Keyword.get(opts, :database)) do
      opts
    else
      Mix.raise("""
      Could not determine a target namespace/database.

      Pass --store <Module>, or --namespace/--database explicitly, or run
      `mix igniter.install hgs_surrealdb_sdk` to generate and register a
      SurrealDB store.
      """)
    end
  end

  defp store_options(opts) do
    case Keyword.get(opts, :store) || Keyword.get(opts, :repo) do
      nil ->
        auto_detect_store_options(opts)

      store_name ->
        store_name
        |> module_from_string!()
        |> store_config!()
    end
  end

  defp repo_path_from_store(opts) do
    opts
    |> store_options()
    |> Keyword.get(:repo_path)
  rescue
    _ -> nil
  end

  defp auto_detect_store_options(opts) do
    case registered_stores() do
      [store] ->
        store_config!(store)

      [] ->
        []

      stores ->
        if manual_scope?(opts) do
          []
        else
          Mix.raise("""
          Multiple SurrealDB stores are registered under :surrealdb_stores \
          (#{Enum.map_join(stores, ", ", &inspect/1)}). Pass --store <Module> to choose one.
          """)
        end
    end
  end

  defp store_config!(store) do
    unless Code.ensure_loaded?(store) and function_exported?(store, :config, 0) do
      Mix.raise("#{inspect(store)} is not loaded or does not expose config/0")
    end

    store.config()
  end

  defp registered_stores do
    Application.get_env(Mix.Project.config()[:app], :surrealdb_stores, [])
  end

  defp manual_scope?(opts) do
    present?(Keyword.get(opts, :namespace)) and present?(Keyword.get(opts, :database))
  end

  defp module_from_string!(store_name) do
    store_name
    |> String.split(".")
    |> Module.concat()
  rescue
    ArgumentError -> Mix.raise("invalid store module: #{inspect(store_name)}")
  end

  defp cli_connection_overrides(opts) do
    []
    |> maybe_put(:endpoint, Keyword.get(opts, :endpoint))
    |> maybe_put(:namespace, Keyword.get(opts, :namespace))
    |> maybe_put(:database, Keyword.get(opts, :database))
    |> maybe_put(:username, Keyword.get(opts, :username))
    |> maybe_put(:password, Keyword.get(opts, :password))
    |> maybe_put(:auth_token, Keyword.get(opts, :auth_token))
    |> maybe_put(:anonymous, Keyword.get(opts, :anonymous))
    |> Keyword.put(:transport, :http)
  end

  defp put_default(opts, key, value) do
    if Keyword.has_key?(opts, key), do: opts, else: Keyword.put(opts, key, value)
  end

  defp put_default_auth(opts) do
    cond do
      Keyword.get(opts, :anonymous) == true ->
        opts

      present?(Keyword.get(opts, :auth_token)) ->
        opts

      present?(Keyword.get(opts, :username)) or present?(Keyword.get(opts, :password)) ->
        opts

      true ->
        opts
        |> Keyword.put(:username, "root")
        |> Keyword.put(:password, "root")
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp project_version do
    Mix.Project.config()
    |> Keyword.get(:version, "unknown")
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)
end
