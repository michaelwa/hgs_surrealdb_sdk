defmodule SurrealDB.Telemetry do
  @moduledoc """
  Telemetry events emitted by the SurrealDB SDK.

  (Full event reference filled in Task 7.)
  """

  require Logger

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
  @spec span(Client.t(), String.t(), keyword(), (-> result)) :: result when result: term()
  def span(%Client{} = client, method, fields, fun) when is_function(fun, 0) do
    start_meta = start_metadata(client, method, fields)

    :telemetry.span(@query_event, start_meta, fn ->
      result = fun.()
      {result, stop_metadata(start_meta, result)}
    end)
  end

  @doc false
  @spec include_query_text?() :: boolean()
  def include_query_text? do
    :hgs_surrealdb_sdk
    |> Application.get_env(:telemetry, [])
    |> Keyword.get(:include_query_text, true)
  end

  @default_logger_id {__MODULE__, :default_logger}

  @doc """
  Attaches a handler that logs each completed query. Opt-in.

  Options:
    * `:level` — log level (default `:debug`).
  """
  @spec attach_default_logger(keyword()) :: :ok | {:error, :already_exists}
  def attach_default_logger(opts \\ []) do
    level = Keyword.get(opts, :level, :debug)

    :telemetry.attach_many(
      @default_logger_id,
      [[:surreal_db, :query, :stop], [:surreal_db, :query, :exception]],
      &__MODULE__.handle_event/4,
      %{level: level}
    )
  end

  @doc "Detaches the handler attached by `attach_default_logger/1`."
  @spec detach_default_logger() :: :ok | {:error, :not_found}
  def detach_default_logger, do: :telemetry.detach(@default_logger_id)

  @doc false
  def handle_event([:surreal_db, :query, :stop], %{duration: duration}, meta, %{level: level}) do
    Logger.log(level, fn ->
      base =
        "SurrealDB #{meta.method} ns=#{meta.namespace} db=#{meta.database} transport=#{meta.transport} (#{format_ms(duration)}ms)"

      case meta.result do
        :ok ->
          base

        :error ->
          base <> " FAILED #{inspect(error_type(meta.error))}: #{error_message(meta.error)}"
      end
    end)
  end

  def handle_event([:surreal_db, :query, :exception], %{duration: duration}, meta, %{level: level}) do
    Logger.log(level, fn ->
      "SurrealDB #{meta.method} ns=#{meta.namespace} db=#{meta.database} RAISED #{inspect(meta.kind)}: #{inspect(meta.reason)} (#{format_ms(duration)}ms)"
    end)
  end

  defp format_ms(duration) do
    (System.convert_time_unit(duration, :native, :microsecond) / 1000) |> Float.round(2)
  end

  defp error_type(%Error{type: type}), do: type
  defp error_type(other), do: other

  defp error_message(%Error{message: message}), do: message
  defp error_message(other), do: inspect(other)

  defp put_query(meta, nil), do: meta

  defp put_query(meta, query) do
    value = if include_query_text?(), do: IO.iodata_to_binary(query), else: :"[redacted]"
    Map.put(meta, :query, value)
  end

  defp put_variables(meta, nil), do: meta

  defp put_variables(meta, variables) when is_map(variables) do
    meta
    |> Map.put(:variable_keys, variables |> Map.keys() |> Enum.sort())
    |> Map.put(:variable_count, map_size(variables))
  end

  defp put_params(meta, nil), do: meta

  defp put_params(meta, params) when is_list(params),
    do: Map.put(meta, :params_count, length(params))
end
