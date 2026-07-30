defmodule SurrealDB.IntegrationCase do
  @moduledoc false

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias SurrealDB.{Client, Identifier}

  @table_key {__MODULE__, :tables}

  @defaults %{
    endpoint: "http://127.0.0.1:18000",
    ws_endpoint: "ws://127.0.0.1:18000/rpc",
    username: "root",
    password: "root",
    namespace: "hgs_sdk_integration",
    database: "hgs_sdk_integration"
  }

  defmacro __using__(_opts) do
    quote do
      use ExUnit.Case, async: false

      import SurrealDB.IntegrationCase,
        only: [
          integration_client: 0,
          integration_ws_client: 0,
          await_ws_ready: 1,
          integration_scope: 0,
          integration_table: 1
        ]
    end
  end

  @spec integration_client() :: Client.t()
  def integration_client do
    config = integration_config!()
    client = connect!(http_options(config))
    ensure_namespace_and_database!(client, config)
    client
  end

  @spec integration_ws_client() :: Client.t()
  def integration_ws_client do
    config = integration_config!()
    http_client = connect!(http_options(config))
    ensure_namespace_and_database!(http_client, config)
    connect_ws!(ws_options(config))
  end

  @spec await_ws_ready(Client.t()) :: Client.t()
  def await_ws_ready(%Client{connection: pid} = client) when is_pid(pid) do
    await_ws_ready(client, 250)
  end

  defp await_ws_ready(%Client{connection: pid} = client, attempts) when attempts > 0 do
    cond do
      not Process.alive?(pid) ->
        raise "integration WebSocket connection exited before setup completed"

      :sys.get_state(pid).setup_complete? ->
        client

      true ->
        Process.sleep(20)
        await_ws_ready(client, attempts - 1)
    end
  end

  defp await_ws_ready(_client, 0),
    do: raise("integration WebSocket setup did not complete within 5 seconds")

  @spec integration_scope() :: String.t()
  def integration_scope do
    "it_#{System.unique_integer([:positive])}"
  end

  @spec integration_table(String.t()) :: String.t()
  def integration_table(suffix) do
    suffix = table_suffix!(suffix)
    table = integration_scope() <> "_" <> suffix
    table = identifier!(table, "integration table")

    Process.put(@table_key, [table | Process.get(@table_key, [])])
    on_exit(fn -> remove_table!(table) end)

    table
  end

  defp integration_config! do
    config = %{
      endpoint: integration_env("SURREALDB_INTEGRATION_ENDPOINT", :endpoint),
      ws_endpoint: integration_env("SURREALDB_INTEGRATION_WS_ENDPOINT", :ws_endpoint),
      username: integration_env("SURREALDB_INTEGRATION_USERNAME", :username),
      password: integration_env("SURREALDB_INTEGRATION_PASSWORD", :password),
      namespace: integration_env("SURREALDB_INTEGRATION_NAMESPACE", :namespace),
      database: integration_env("SURREALDB_INTEGRATION_DATABASE", :database)
    }

    validate_endpoint!(config.endpoint)
    validate_endpoint!(config.ws_endpoint)

    %{
      config
      | namespace: identifier!(config.namespace, "namespace"),
        database: identifier!(config.database, "database")
    }
  end

  defp integration_env(variable, key), do: System.get_env(variable, Map.fetch!(@defaults, key))

  defp validate_endpoint!(endpoint) do
    if external_endpoint?(endpoint) and
         System.get_env("SURREALDB_INTEGRATION_ALLOW_EXTERNAL") != "1" do
      raise ArgumentError,
            "refusing external integration endpoint #{inspect(endpoint)}; set SURREALDB_INTEGRATION_ALLOW_EXTERNAL=1 to allow it"
    end
  end

  defp external_endpoint?(endpoint) do
    uri = URI.parse(endpoint)
    uri.host not in ["127.0.0.1", "localhost"] or uri.port != 18_000
  end

  defp http_options(config) do
    [
      endpoint: config.endpoint,
      namespace: config.namespace,
      database: config.database,
      username: config.username,
      password: config.password
    ]
  end

  defp ws_options(config) do
    [
      endpoint: config.ws_endpoint,
      namespace: config.namespace,
      database: config.database,
      username: config.username,
      password: config.password
    ]
  end

  defp connect!(options) do
    case SurrealDB.connect(options) do
      {:ok, client} ->
        client

      {:error, error} ->
        raise ArgumentError, "failed to configure integration client: #{error.message}"
    end
  end

  defp connect_ws!(options) do
    case SurrealDB.connect_ws(options) do
      {:ok, client} ->
        client

      {:error, error} ->
        raise ArgumentError, "failed to connect integration WebSocket client: #{error.message}"
    end
  end

  defp ensure_namespace_and_database!(client, config) do
    query = """
    DEFINE NAMESPACE IF NOT EXISTS #{config.namespace};
    USE NS #{config.namespace};
    DEFINE DATABASE IF NOT EXISTS #{config.database};
    """

    query!(client, query)
  end

  defp remove_table!(table) do
    client = integration_client()
    query!(client, "REMOVE TABLE IF EXISTS #{table};")
  end

  defp query!(client, query) do
    case SurrealDB.query(client, query) do
      {:ok, _result} ->
        :ok

      {:error, error} ->
        raise ArgumentError, "integration database query failed: #{error.message}"
    end
  end

  defp table_suffix!(suffix) do
    suffix = identifier!(suffix, "integration table suffix")

    if String.contains?(suffix, ":") do
      raise ArgumentError, "integration table suffix must be a table identifier"
    end

    suffix
  end

  defp identifier!(value, kind) do
    case Identifier.validate(value) do
      {:ok, identifier} -> identifier
      {:error, error} -> raise ArgumentError, "invalid integration #{kind}: #{error.message}"
    end
  end
end
