defmodule SurrealDB.Telemetry do
  @moduledoc """
  Telemetry events emitted by the SurrealDB SDK.

  (Full event reference filled in Task 7.)
  """

  alias SurrealDB.Client
  alias SurrealDB.Error

  @query_event [:surreal_db, :query]

  @doc """
  Lists every telemetry event the SDK emits. Useful for `Telemetry.Metrics`
  specs and tests.
  """
  @spec events() :: [[atom()]]
  def events do
    [
      @query_event ++ [:start],
      @query_event ++ [:stop],
      @query_event ++ [:exception],
      [:surreal_db, :connection, :connected],
      [:surreal_db, :connection, :disconnected],
      [:surreal_db, :connection, :reconnecting]
    ]
  end

  @doc false
  @spec start_metadata(Client.t(), String.t(), keyword()) :: map()
  def start_metadata(%Client{} = client, method, fields) do
    %{
      method: method,
      namespace: client.namespace,
      database: client.database,
      transport: client.transport,
      endpoint: client.endpoint
    }
    |> put_query(Keyword.get(fields, :query))
    |> put_variables(Keyword.get(fields, :variables))
    |> put_params(Keyword.get(fields, :params))
  end

  @doc false
  @spec stop_metadata(map(), term()) :: map()
  def stop_metadata(start_meta, :ok), do: Map.merge(start_meta, %{result: :ok, error: nil})
  def stop_metadata(start_meta, {:ok, _}), do: Map.merge(start_meta, %{result: :ok, error: nil})

  def stop_metadata(start_meta, {:error, %Error{} = error}),
    do: Map.merge(start_meta, %{result: :error, error: error})

  def stop_metadata(start_meta, {:error, other}),
    do: Map.merge(start_meta, %{result: :error, error: other})

  @doc false
  @spec include_query_text?() :: boolean()
  def include_query_text? do
    :hgs_surrealdb_sdk
    |> Application.get_env(:telemetry, [])
    |> Keyword.get(:include_query_text, true)
  end

  defp put_query(meta, nil), do: meta

  defp put_query(meta, query) do
    value = if include_query_text?(), do: IO.iodata_to_binary(query), else: :"[redacted]"
    Map.put(meta, :query, value)
  end

  defp put_variables(meta, nil), do: meta

  defp put_variables(meta, variables) when is_map(variables) do
    meta
    |> Map.put(:variable_keys, Map.keys(variables))
    |> Map.put(:variable_count, map_size(variables))
  end

  defp put_params(meta, nil), do: meta

  defp put_params(meta, params) when is_list(params),
    do: Map.put(meta, :params_count, length(params))
end
